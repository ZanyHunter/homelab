# *arr Stack (Sonarr/Radarr/Prowlarr/qBittorrent)

An automated media-acquisition pipeline feeding into Jellyfin: Prowlarr manages indexers, Sonarr/Radarr watch for TV/movie releases and hand them to qBittorrent, and completed downloads get imported into the library Jellyfin already serves. The one hard requirement driving most of this app's shape: qBittorrent's torrent traffic exposes peer IPs to trackers/swarms in a way nothing else in this repo does, so it must go through a VPN tunnel — specifically Proton VPN's free plan, routed to a Switzerland exit.

## Two apps, split by security posture, not by convenience

Everything here could have lived in one `apps/arr-stack/` namespace. It doesn't, because qBittorrent's VPN sidecar (Gluetun) needs the `NET_ADMIN` Linux capability and `/dev/net/tun` to build its WireGuard tunnel and run its own kill switch — a capability this repo has never granted to any app before. `NET_ADMIN` is disallowed under both `restricted` and `baseline` Pod Security Standards, so it needs a `privileged`-PSA namespace, the same tier this repo otherwise reserves for exactly three infra DaemonSets (`metallb-system`, `csi-driver-nfs`, `monitoring`).

Rather than make the whole stack privileged, the split is:

- **`apps/arr-stack/`** — namespace `arr-stack`, `restricted` PSA. Sonarr, Radarr, Prowlarr, each with its own oauth2-proxy forward-auth instance. None of the three ever touches a peer or tracker directly — Prowlarr's indexer queries and Sonarr/Radarr's metadata-provider lookups are plain HTTPS, no different from any other app's egress here.
- **`apps/arr-downloader/`** — namespace `arr-downloader`, `privileged` PSA (set directly as a namespace label, same GitOps mechanism every other app namespace uses — no Tofu change was needed; the three existing `privileged` namespaces are Tofu-managed for unrelated bootstrap-ordering reasons, not because setting a PSA label itself requires Tofu). One Deployment, two containers in the **same pod**: Gluetun and qBittorrent. This is the only way for qBittorrent's traffic to actually transit Gluetun's tunnel — Kubernetes' network-namespace-sharing unit is the pod, and the classic Docker `network_mode: service:gluetun` pattern has no separate-Deployment equivalent here.

This was a real, user-confirmed tradeoff, not a default: an earlier draft considered putting the entire stack behind Gluetun to match "all traffic" literally, but that would have made the whole namespace privileged for no real security benefit (Sonarr/Radarr/Prowlarr never expose an IP to a stranger the way BitTorrent does) and would have meant Gluetun's kill switch taking the *entire* stack offline if the tunnel ever drops, not just the downloader.

Sonarr/Radarr still need to reach qBittorrent's API directly (to submit and monitor downloads) — this needs a cross-namespace NetworkPolicy pair (egress from `arr-stack`, ingress into `arr-downloader`), the second use of the precedent Matrix Authentication Service established for Synapse ↔ MAS (see [Matrix](./matrix.md)'s MAS section) — the first NetworkPolicy shape in this repo naming another app's namespace directly.

## Storage: a third use of the static-PV-into-a-real-path pattern, first with per-environment paths

Jellyfin's media library ([Jellyfin](./jellyfin.md)) established mounting a static PV directly into a hand-populated NFS directory rather than a dynamically-provisioned PVC; Pinchflat extended it read-write for its own downloads. This is that pattern's third use — and its first where the underlying path genuinely differs between dev and prod.

Jellyfin's and Pinchflat's shared paths were a deliberate exception to this repo's usual per-environment split, justified because their content is either read-only or purely additive. This app is different: Sonarr/Radarr actively rename, hardlink, and delete files during import. A dev misconfiguration touching the real household library would have real consequences Pinchflat's append-only downloads never risked — so storage here is scoped per environment instead, confirmed with the user rather than assumed:

- **dev**: a new, isolated NFS directory (`/mnt/Main/k8s-dev/arr-downloads/`, created by hand, **not** under Jellyfin's `jellyfin-media` export at all). Its contents are invisible to Jellyfin, which only ever reads the one real shared export — this exists purely to exercise the pipeline mechanics (Sonarr/Radarr/qBittorrent/OIDC/VPN egress) safely against disposable test content.
- **prod**: a new `Downloads/` subdirectory inside the real `jellyfin-media` export, alongside the existing `Movies`/`TV Shows`/`Other`/`YouTube`. Sonarr/Radarr organize real files directly into the same `Movies`/`TV Shows` folders Jellyfin already scans.

Every container mounts this tree at the identical absolute path — qBittorrent at `/media/Downloads`, Sonarr/Radarr at `/media` (giving them `/media/Downloads`, `/media/Movies`, `/media/TV Shows`) — specifically so Sonarr/Radarr can **hardlink** completed downloads into the library instead of copying them. Hardlinks require the source and destination to be on the same filesystem/mount; keeping every container's view at the same path avoids needing Sonarr/Radarr's separate "Remote Path Mapping" feature (the approach TRaSH-guides recommends).

Manual, one-time NAS prep is required before first deploy: create and `chown`/`chmod` (uid/gid 1000) the `Downloads`/`Movies`/`TV Shows` tree under both the dev-only path and (if not already shaped this way) prod's `jellyfin-media` export.

## Networking

Standard per-namespace trio (`default-deny-all`, `allow-dns-egress`, `allow-same-namespace`) in both namespaces, plus:

- **Internet egress for Sonarr/Radarr/Prowlarr**: the exact rule shape Pinchflat established (`apps/youtube-archiver/base/network-policies.yaml`) — scoped to those three pods' labels, `0.0.0.0/0` on `443/TCP` only.
- **VPN-establishment egress for the qBittorrent+Gluetun pod**: `0.0.0.0/0` on `51820/UDP` (WireGuard's conventional port — confirm against the actual Proton config, adjust if different) and `443/TCP` (Gluetun's own startup calls). Can't scope to a fixed destination IP any more than LiveKit's STUN-detection egress rule could (`apps/matrix-livekit/`) — Proton's endpoint isn't knowable in advance.
- **Cross-namespace Sonarr/Radarr → qBittorrent**: covered above.
- **Gluetun's own firewall** (separate from Kubernetes NetworkPolicy — its own internal iptables kill switch) needs `FIREWALL_INPUT_PORTS=8080` so Ingress/Sonarr/Radarr traffic can reach qBittorrent's WebUI through Gluetun's default-deny-inbound posture.

An open question flagged rather than assumed: once Gluetun's tunnel is up, qBittorrent's actual torrent traffic exits via Gluetun's internal `tun0` interface, not the pod's CNI-attached `eth0`. Whether this cluster's CNI enforces NetworkPolicy against `tun0` traffic the same way it does `eth0` traffic is unverified — Gluetun's own internal kill switch is the real leak-prevention mechanism regardless of how that turns out.

## Images: hotio, and a real gotcha that changed `arr-stack`'s PSA level

Sonarr, Radarr, Prowlarr, and qBittorrent all use `ghcr.io/hotio/*:release` rather than the more commonly-referenced `lscr.io/linuxserver/*` images, chosen expecting hotio to run as an arbitrary non-root uid directly rather than needing linuxserver.io's root-start-then-drop model. **Found live to be wrong**: hotio's images use the identical s6-overlay preinit as linuxserver.io's. Forcing `restricted` PSA's non-root-from-the-first-process onto them failed outright —

```
/package/admin/s6-overlay/libexec/preinit: fatal: /run belongs to uid 0 instead of 1000, has insecure and/or unworkable permissions, and we're lacking the privileges to fix it.
```

— for Sonarr/Radarr/Prowlarr, and a related failure crash-looped qBittorrent even without `runAsNonRoot` forced, because its container still had `capabilities: {drop: ["ALL"]}`, which strips `CAP_CHOWN` from root too: `chown: changing ownership of '/config': Operation not permitted`.

The real fix: `apps/arr-stack/base/namespace.yaml` moved from `restricted` to **`baseline`** PSA — the same can't-quite-reach-restricted tier `minio`/`velero` already use for their own Helm hook Jobs ([NetworkPolicies and Pod Security Admission](./network-policies.md)) — and all four containers (Sonarr, Radarr, Prowlarr, qBittorrent) had `runAsNonRoot`/`runAsUser`/`capabilities: drop: ["ALL"]` removed from their securityContext entirely, letting s6-overlay's preinit run as root and do its own chown/setup before dropping to `PUID`/`PGID` internally, exactly like a normal Docker deployment of these images would. `apps/arr-downloader/` needed no namespace change (already `privileged`, a superset of `baseline`) — just the same container-level fix on qBittorrent's own securityContext. `allowPrivilegeEscalation: false` stayed on all four; dropping privileges via `setuid()` doesn't need privilege escalation, only gaining them would.

hotio doesn't publish immutable per-version tags the way this repo otherwise prefers (only floating `release`/`testing`/`nightly` channels) — `:release` is the closest available, their own documented stable channel.

## qBittorrent's own login, on top of oauth2-proxy's

Found live: completing Keycloak login through oauth2-proxy still landed on qBittorrent's own separate WebUI login page. This is expected, not a bug in the forward-auth wiring — oauth2-proxy's `auth-url` check happens entirely at ingress-nginx, gating whether a request reaches qBittorrent's Ingress at all; it has no mechanism to also authenticate *into* qBittorrent's own independent account system once the request is let through.

qBittorrent has a documented mechanism for exactly this "behind a reverse proxy with its own auth" scenario, applied here via its own WebUI API (`POST /api/v2/app/setPreferences`, matching this repo's "managed by hand, not by Tofu/GitOps" precedent for admin-UI-only settings — done via the API instead of clicking through the UI, functionally identical):

- `web_ui_reverse_proxy_enabled: true` + `web_ui_reverse_proxies_list: "10.244.0.0/16"` (the cluster's pod CIDR) — without this, qBittorrent sees every request as originating from ingress-nginx's own pod IP rather than the real client, since it doesn't trust `X-Forwarded-For` from an untrusted source by default.
- `bypass_auth_subnet_whitelist_enabled: true` + `bypass_auth_subnet_whitelist: "192.168.160.32/27"` (dev's `network_cidr`) — once the real client IP is resolved via the trusted-proxy setting above, this skips qBittorrent's own login for that subnet, since oauth2-proxy has already verified the user via Keycloak. This doesn't widen access beyond what NetworkPolicy already permits — only ingress-nginx and Sonarr/Radarr can reach qBittorrent's port at all.

Also set a permanent WebUI password in the same call — qBittorrent generates a new temporary one on every restart until an operator sets a real one, which would otherwise also silently break Sonarr/Radarr's own download-client login to qBittorrent's API on the next pod restart.

This lives entirely in qBittorrent's own persistent `/config` state (its Ceph-backed PVC), not in git — same category as Jellyfin's SSO plugin config or LubeLogger's `EnableAuth` flag. A future qBittorrent PVC loss/recreation needs this redone by hand.

## Secrets

Four new Keycloak clients (`sonarr-oauth2-proxy`, `radarr-oauth2-proxy`, `prowlarr-oauth2-proxy`, `qbittorrent-oauth2-proxy`), one per app, following the same 1-app-1-client shape every other oauth2-proxy app here uses — deliberately *not* one client shared across all four oauth2-proxy instances, which would have been a genuinely new, unprecedented pattern in this repo. Each app's own oauth2-proxy cookie secret is ksops-encrypted, generated via `openssl rand -hex 16` (a raw 32-byte value — `openssl rand -base64 32` produces a 44-character string that crashes oauth2-proxy, the exact bug already hit and fixed for Pinchflat).

Proton's WireGuard credentials (`WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`) have no Tofu counterpart — Proton doesn't originate from this repo's own generated state — so they're ksops-encrypted in `apps/arr-downloader/base/proton-vpn-credentials.enc.yaml`, same category as any oauth2-proxy cookie secret. Obtaining them is a manual, one-time step: log into `account.protonvpn.com`, generate a WireGuard configuration, and copy the `[Interface]` section's `PrivateKey`/`Address` into the secret before re-encrypting with `sops -e -i`.

**Known constraint, not solved here**: Proton's free plan allows exactly one simultaneous connection. dev and prod can't both hold an active tunnel on the same account — acceptable for now since prod deployment is deferred (see Verification below), but a real blocker whenever prod promotion is considered. Options at that point: a second free Proton account, or accepting that dev and prod alternate access to the one account.

## Verification

Verified live on dev, past the design-complete/test-build-only stage: `keycloak-realm`'s `tofu apply` created all four new oauth2-proxy clients cleanly (12 resources — client + `random_password` + `kubernetes_secret` each — zero drift elsewhere), both `dev` Kustomize builds were confirmed via the ArgoCD repo-server test-build pattern (ksops decrypting real secrets correctly, no leftover `__TOKEN__` placeholders), and applying that output directly to dev showed:

- **The VPN actually works, not just "the pod is Running"**: Gluetun's own logs report a successful WireGuard handshake to Proton's `CH-FREE#11` endpoint, and its `[ip getter]` log line confirms the tunnel's egress IP resolves to **Switzerland, Zurich** — the whole reason this app's architecture looks the way it does, genuinely confirmed rather than assumed. Stable for 8+ hours with zero restarts on the Gluetun+qBittorrent pod.
- **The privileged-PSA/`NET_ADMIN` design is sound**: the API server admitted the Gluetun+qBittorrent pod's capability request under `privileged` PSA with no admission errors, on the first apply.
- **A real, live-found gotcha changed `arr-stack`'s PSA level from `restricted` to `baseline`** — see the Images section above for the full story (hotio's images need to start as root, same as linuxserver.io's, which `restricted` flatly disallows).
- **All four apps reach a real Keycloak login, not just "the client exists"**: an unauthenticated request to each hostname redirects through `/oauth2/start` to a real Keycloak authorize URL with the correct `client_id`/`redirect_uri`/scope for that specific app, and fetching Sonarr's authorize URL rendered Keycloak's actual `Sign in to Homelab` login form.
- **The new cross-namespace NetworkPolicy actually works**: `kubectl exec`'d from Sonarr's pod (`arr-stack`) to qBittorrent's Service DNS (`arr-downloader`) and got a real HTTP response (`403 Forbidden` — qBittorrent's own CSRF/auth check, not a network-level block; a blocked connection would have timed out with no response at all, not returned a real HTTP status).
- Real Let's Encrypt certificates issued for all four hostnames on the first apply.
- **A real post-merge gotcha, found by the user actually logging in**: completing Keycloak login still landed on qBittorrent's own separate login page (see the section above) — fixed via qBittorrent's own API, confirmed by a fresh login with the new permanent password returning a real authenticated session (`/api/v2/app/version` succeeding, not a 403) and the reverse-proxy/whitelist preferences reading back exactly as set. The actual end-to-end browser experience (Keycloak login landing directly in qBittorrent with no second prompt) still needs the user's own confirmation, since it requires a real interactive login this environment can't perform.

**Not yet exercised**: a full pipeline run (a real indexer configured in Prowlarr, synced to Sonarr/Radarr, a real download completing in qBittorrent, and Sonarr/Radarr importing/hardlinking it into `/media/Movies` or `/media/TV Shows`) — this needs interactive indexer/account setup through each app's own UI, left as a follow-up rather than done speculatively here. Also unresolved: whether Kubernetes NetworkPolicy meaningfully constrains Gluetun's post-tunnel `tun0` traffic or only its pre-tunnel `eth0` traffic — Gluetun's own internal kill switch is the real leak-prevention mechanism regardless of how that turns out, so this was left as a documented open question rather than chased further.

Public exposure and prod deployment both stay deferred, matching every other app in this repo's rollout history.
