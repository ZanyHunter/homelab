# Wire Up the *arr Stack (Sonarr/Radarr/Prowlarr/qBittorrent)

Everything in this guide lives entirely in each app's own persistent runtime state (its Ceph-backed `/config` PVC) — none of it is captured in git, Kustomize, or Tofu. A PVC loss/recreation, or standing this app up fresh in a new environment (e.g. promoting to prod), needs every step here redone by hand. See [*arr Stack](../explanation/arr-stack.md) for the architecture and why none of this is templated.

All commands assume `kubectl` is pointed at the right cluster and namespaces `arr-stack`/`arr-downloader` already exist and are `Running`.

## 1. Get each app's auto-generated API key

Sonarr, Radarr, and Prowlarr each generate their own API key on first boot, stored in `/config/config.xml`:

```bash
kubectl exec -n arr-stack deploy/sonarr   -- grep -o "<ApiKey>[^<]*</ApiKey>" /config/config.xml
kubectl exec -n arr-stack deploy/radarr   -- grep -o "<ApiKey>[^<]*</ApiKey>" /config/config.xml
kubectl exec -n arr-stack deploy/prowlarr -- grep -o "<ApiKey>[^<]*</ApiKey>" /config/config.xml
```

qBittorrent's WebUI admin username/password is `admin` / a temporary password printed once on first boot, found via:

```bash
kubectl logs -n arr-downloader deploy/gluetun-qbittorrent -c qbittorrent | grep -i "temporary password"
```

That temporary password rotates on every pod restart until step 2 below sets a permanent one.

## 2. Port-forward all three arr-stack apps for local API access

Constructing JSON payloads is much easier from your own shell than nested inside `kubectl exec`. Run these in the background:

```bash
kubectl port-forward -n arr-stack svc/sonarr 18989:8989 &
kubectl port-forward -n arr-stack svc/radarr 17878:7878 &
kubectl port-forward -n arr-stack svc/prowlarr 19696:9696 &
```

qBittorrent's own API is only reachable from inside the `arr-downloader` pod itself (`kubectl exec ... curl http://localhost:8080/...`) since it shares Gluetun's network namespace — its firewall only allows the ports explicitly opened via `FIREWALL_INPUT_PORTS` (`apps/arr-downloader/base/gluetun-qbittorrent.yaml`), which doesn't include an arbitrary local port-forward.

## 3. Fix qBittorrent's own login stacking on top of oauth2-proxy

oauth2-proxy's forward-auth only gates whether ingress-nginx lets a request through — it can't also log you into qBittorrent's own separate internal account system. Fix via qBittorrent's own reverse-proxy-trust mechanism, applied through its API:

```bash
# From inside the qbittorrent container (see step 2's note on why):
kubectl exec -n arr-downloader deploy/gluetun-qbittorrent -c qbittorrent -- sh -c '
curl -s -c /tmp/cookies.txt -H "Referer: http://localhost:8080" \
  --data "username=admin&password=<TEMP_PASSWORD_FROM_STEP_1>" \
  http://localhost:8080/api/v2/auth/login

curl -s -b /tmp/cookies.txt -H "Referer: http://localhost:8080" \
  --data-urlencode '"'"'json={"web_ui_reverse_proxy_enabled": true, "web_ui_reverse_proxies_list": "<POD_CIDR>", "bypass_auth_subnet_whitelist_enabled": true, "bypass_auth_subnet_whitelist": "<ENV_NETWORK_CIDR>,<POD_CIDR>", "web_ui_password": "<NEW_PERMANENT_PASSWORD>", "save_path": "/media/Downloads"}'"'"' \
  http://localhost:8080/api/v2/app/setPreferences
'
```

- `<POD_CIDR>`: the cluster's pod network (dev: `10.244.0.0/16` — get any cluster's via `kubectl get nodes -o jsonpath='"'"'{range .items[*]}{.spec.podCIDR}{"\n"}{end}'"'"'` and take the common supernet). This is what lets qBittorrent trust `X-Forwarded-For` from ingress-nginx instead of seeing every request as coming from ingress-nginx's own pod IP.
- `<ENV_NETWORK_CIDR>`: that environment's `network_cidr` from `env.hcl` (dev: `192.168.160.32/27`) — the real LAN/VPN subnet browser clients connect from.
- `bypass_auth_subnet_whitelist` needs **both** CIDRs, comma-separated — found live that `<ENV_NETWORK_CIDR>` alone never matched. Checking ingress-nginx's own access log for a failed request showed its `$remote_addr` was already a pod-network address (`10.244.6.1`, not a real LAN IP) by the time it reached ingress-nginx — something upstream (most likely kube-proxy/MetalLB's default SNAT behavior for `externalTrafficPolicy: Cluster`) masks the real client IP before ingress-nginx ever sees it, so that's also what ends up in `X-Forwarded-For`. Include `<POD_CIDR>` in the whitelist too (not just the trusted-proxies-list field above) to match what's actually observed.
- `save_path`: qBittorrent's own "default save path" preference — mounting the `arr-downloads` PVC at `/media/Downloads` doesn't automatically tell qBittorrent to save there; this is a separate internal setting.
- Pick `<NEW_PERMANENT_PASSWORD>` yourself (e.g. `openssl rand -base64 24 | tr -d '=+/' | head -c 24`) — Sonarr/Radarr's download-client login (step 4) needs a password that doesn't rotate on every pod restart.

**If login still fails after this**: check `kubectl logs -n ingress-nginx deploy/ingress-nginx-controller | grep qbittorrent` for the actual `$remote_addr` ingress-nginx is logging on the failing request, and add whatever CIDR that address actually falls in to `bypass_auth_subnet_whitelist` — don't assume the LAN subnet is what's really arriving.

Verify it took:

```bash
kubectl exec -n arr-downloader deploy/gluetun-qbittorrent -c qbittorrent -- sh -c '
curl -s -b /tmp/cookies.txt http://localhost:8080/api/v2/app/preferences
' | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['web_ui_reverse_proxy_enabled'], d['bypass_auth_subnet_whitelist_enabled'], d['save_path'])"
```

## 4. Add qBittorrent as a download client in Sonarr and Radarr

Fetch the real field schema first rather than guessing — Sonarr's `tvCategory`/Radarr's `movieCategory` fields differ:

```bash
curl -s http://localhost:18989/api/v3/downloadclient/schema -H "X-Api-Key: <SONARR_API_KEY>" \
  | python3 -c "import json,sys; [print(json.dumps(d,indent=2)) for d in json.load(sys.stdin) if d['implementation']=='QBittorrent']"
```

Then `POST` the filled-in object (host/port/username/password are the fields that matter; everything else can keep its schema default):

```bash
curl -s -X POST http://localhost:18989/api/v3/downloadclient \
  -H "X-Api-Key: <SONARR_API_KEY>" -H "Content-Type: application/json" \
  --data '{
    "enable": true, "protocol": "torrent", "priority": 1,
    "removeCompletedDownloads": true, "removeFailedDownloads": true,
    "name": "qBittorrent", "implementation": "QBittorrent", "configContract": "QBittorrentSettings",
    "fields": [
      {"name": "host", "value": "qbittorrent.arr-downloader.svc.cluster.local"},
      {"name": "port", "value": 8080},
      {"name": "useSsl", "value": false},
      {"name": "username", "value": "admin"},
      {"name": "password", "value": "<QBITTORRENT_PERMANENT_PASSWORD>"},
      {"name": "tvCategory", "value": "tv-sonarr"},
      {"name": "recentTvPriority", "value": 0}, {"name": "olderTvPriority", "value": 0},
      {"name": "initialState", "value": 0}
    ]
  }'
```

Same shape for Radarr on `http://localhost:17878/api/v3/downloadclient` with `<RADARR_API_KEY>`, `movieCategory: "radarr"`, `recentMoviePriority`/`olderMoviePriority` instead of the `tv*` field names.

`qbittorrent.arr-downloader.svc.cluster.local` is the in-cluster Service DNS name — identical in every environment regardless of dev/prod, since it resolves within whichever cluster `kubectl` is pointed at.

**Verify it actually works, not just that it saved** — force a fresh health check and confirm no `RemotePathMappingCheck`/connection errors:

```bash
curl -s -X POST http://localhost:18989/api/v3/command -H "X-Api-Key: <SONARR_API_KEY>" -H "Content-Type: application/json" --data '{"name":"CheckHealth"}'
sleep 3
curl -s http://localhost:18989/api/v3/health -H "X-Api-Key: <SONARR_API_KEY>"
```

A lingering `RemotePathMappingCheck` error here almost always means step 3's `save_path` fix wasn't applied (or the pod hasn't picked it up yet) — Radarr reported qBittorrent's downloads as landing in its factory-default `/app/qBittorrent/downloads`, which doesn't exist in this deployment, until that was fixed.

## 5. Add indexers to Prowlarr

Prowlarr ships ~600 built-in indexer definitions. Fetch the schema, pick ones with `"privacy": "public"` (no account needed), and check whether they need FlareSolverr (not deployed here — see [*arr Stack](../explanation/arr-stack.md)):

```bash
curl -s http://localhost:19696/api/v1/indexer/schema -H "X-Api-Key: <PROWLARR_API_KEY>" > /tmp/prowlarr-schema.json
python3 -c "
import json
data = json.load(open('/tmp/prowlarr-schema.json'))
for d in data:
    if d.get('privacy') == 'public':
        needs_fs = any('flaresolverr' in str(f.get('name','')).lower() for f in d['fields'])
        if not needs_fs:
            print(d['name'])
"
```

Even indexers whose Prowlarr definition doesn't mention FlareSolverr can still be live-blocked by Cloudflare at the actual site (found live: `LimeTorrents`, `The Pirate Bay`, and `Magnet Cat` all rejected with `"blocked by CloudFlare Protection"` despite passing the schema check) — Prowlarr tests real connectivity before saving, so a `400` response here means try a different one, not that something's misconfigured.

Confirmed working without FlareSolverr as of this writing: **Knaben**, **TorrentDownload**, **World-torrent**, **YTS** (movies only — no TV categories). To add one, get its schema entry, set a `baseUrl` from its `indexerUrls`, and set a valid `appProfileId` (Prowlarr's default "Standard" profile is usually `id: 1` — confirm via `GET /api/v1/appprofile`):

```bash
python3 -c "
import json
data = json.load(open('/tmp/prowlarr-schema.json'))
for d in data:
    if d['name'] == 'Knaben':
        for f in d['fields']:
            if f['name'] == 'baseUrl':
                f['value'] = d['indexerUrls'][0]
        d['enable'] = True
        d['appProfileId'] = 1
        json.dump(d, open('/tmp/knaben.json', 'w'))
"
curl -s -X POST http://localhost:19696/api/v1/indexer -H "X-Api-Key: <PROWLARR_API_KEY>" -H "Content-Type: application/json" --data @/tmp/knaben.json
```

Repeat per indexer. `Torrent Downloads` (a different site from `TorrentDownload` above) saved successfully in Prowlarr but never propagated to Sonarr/Radarr via the app sync in step 6, for reasons not tracked down — a real, unresolved quirk, not something silently assumed fine.

## 6. Connect Prowlarr to Sonarr and Radarr

This is what actually syncs indexers out to each app — adding indexers to Prowlarr alone does nothing for Sonarr/Radarr until this step:

```bash
curl -s http://localhost:19696/api/v1/applications/schema -H "X-Api-Key: <PROWLARR_API_KEY>" > /tmp/prowlarr-apps-schema.json
python3 -c "
import json
data = json.load(open('/tmp/prowlarr-apps-schema.json'))
for d in data:
    if d['implementation'] == 'Sonarr':
        for f in d['fields']:
            if f['name'] == 'prowlarrUrl': f['value'] = 'http://prowlarr.arr-stack.svc.cluster.local:9696'
            elif f['name'] == 'baseUrl': f['value'] = 'http://sonarr.arr-stack.svc.cluster.local:8989'
            elif f['name'] == 'apiKey': f['value'] = '<SONARR_API_KEY>'
        d['name'] = 'Sonarr'
        d['enable'] = True
        json.dump(d, open('/tmp/prowlarr-app-sonarr.json', 'w'))
"
curl -s -X POST http://localhost:19696/api/v1/applications -H "X-Api-Key: <PROWLARR_API_KEY>" -H "Content-Type: application/json" --data @/tmp/prowlarr-app-sonarr.json
```

Same shape for Radarr (`implementation == 'Radarr'`, `baseUrl` → `radarr.arr-stack.svc.cluster.local:7878`, its own API key). Both connections are live-tested by Prowlarr before saving — a `201` means it actually reached that app, not just that the object validated.

Force an immediate sync rather than waiting for the scheduled interval:

```bash
curl -s -X POST http://localhost:19696/api/v1/command -H "X-Api-Key: <PROWLARR_API_KEY>" -H "Content-Type: application/json" --data '{"name":"ApplicationIndexerSync"}'
sleep 10
curl -s http://localhost:18989/api/v3/indexer -H "X-Api-Key: <SONARR_API_KEY>"   # should list the synced indexers
curl -s http://localhost:17878/api/v3/indexer -H "X-Api-Key: <RADARR_API_KEY>"
```

## 7. Verify the whole pipeline actually works

A real, read-only search query (no download, safe to run) is the fastest way to confirm every indexer is genuinely reachable and returning current results, not just configured:

```bash
curl -s "http://localhost:19696/api/v1/search?query=ubuntu&type=search&indexerIds=1&indexerIds=2&indexerIds=3&indexerIds=4" \
  -H "X-Api-Key: <PROWLARR_API_KEY>" | python3 -c "import json,sys; print(len(json.load(sys.stdin)), 'results')"
```

Confirmed live on dev: 185 real results with real seeder counts across all configured indexers.

Not covered by this guide: an actual end-to-end grab (searching for a real show/movie in Sonarr/Radarr's own UI, sending it to qBittorrent, and confirming the completed download gets hardlinked into `/media/Movies` or `/media/TV Shows`) — this exercises the same wiring set up here, just through each app's own UI instead of its API.
