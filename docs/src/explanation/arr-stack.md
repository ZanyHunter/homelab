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

## Images: hotio over linuxserver.io

Sonarr, Radarr, Prowlarr, and qBittorrent all use `ghcr.io/hotio/*:release` rather than the more commonly-referenced `lscr.io/linuxserver/*` images. linuxserver.io's images are built around an s6-overlay init that typically starts as root before dropping to the configured `PUID`/`PGID` — a model that tends to conflict with Kubernetes forcing a non-root start from the very first process, which `restricted` PSA requires in `arr-stack`. hotio's images are built to run as an arbitrary non-root uid directly. hotio doesn't publish immutable per-version tags the way this repo otherwise prefers (only floating `release`/`testing`/`nightly` channels) — `:release` is the closest available, their own documented stable channel.

## Secrets

Four new Keycloak clients (`sonarr-oauth2-proxy`, `radarr-oauth2-proxy`, `prowlarr-oauth2-proxy`, `qbittorrent-oauth2-proxy`), one per app, following the same 1-app-1-client shape every other oauth2-proxy app here uses — deliberately *not* one client shared across all four oauth2-proxy instances, which would have been a genuinely new, unprecedented pattern in this repo. Each app's own oauth2-proxy cookie secret is ksops-encrypted, generated via `openssl rand -hex 16` (a raw 32-byte value — `openssl rand -base64 32` produces a 44-character string that crashes oauth2-proxy, the exact bug already hit and fixed for Pinchflat).

Proton's WireGuard credentials (`WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`) have no Tofu counterpart — Proton doesn't originate from this repo's own generated state — so they're ksops-encrypted in `apps/arr-downloader/base/proton-vpn-credentials.enc.yaml`, same category as any oauth2-proxy cookie secret. Obtaining them is a manual, one-time step: log into `account.protonvpn.com`, generate a WireGuard configuration, and copy the `[Interface]` section's `PrivateKey`/`Address` into the secret before re-encrypting with `sops -e -i`.

**Known constraint, not solved here**: Proton's free plan allows exactly one simultaneous connection. dev and prod can't both hold an active tunnel on the same account — acceptable for now since prod deployment is deferred (see Verification below), but a real blocker whenever prod promotion is considered. Options at that point: a second free Proton account, or accepting that dev and prod alternate access to the one account.

## Verification

Design-complete and confirmed via the ArgoCD repo-server test-build pattern for all four overlay combinations (`arr-stack`/`arr-downloader` × dev/prod): each builds cleanly with no leftover `__TOKEN__` placeholders, ksops decrypts every secret correctly, and a `kubectl apply --dry-run=server` confirms every cluster-scoped resource (namespaces, PSA labels, the static PVs) is schema-valid against the live dev API server.

Live deployment is deliberately held, not yet attempted: it needs two things only the user can do — a real Proton VPN WireGuard config (`account.protonvpn.com`, copied into `apps/arr-downloader/base/proton-vpn-credentials.enc.yaml`, currently placeholder text) and the dev-only NAS directory tree (`/mnt/Main/k8s-dev/arr-downloads/{Downloads,Movies,TV Shows}`, chowned to uid/gid 1000) created by hand. Applying with placeholder credentials now would just crash-loop Gluetun and leave the static PVCs unbound — informative about nothing except the one thing not yet directly confirmed (whether the API server actually admits a pod requesting `NET_ADMIN` under `privileged` PSA the way this is designed), which is deferred to the same verification pass rather than done in isolation.

This section will be updated with what's actually found once both prerequisites are in place and a real `kubectl apply` runs — in particular:

- Whether Gluetun's tunnel actually establishes against Proton's free-tier Switzerland server, confirmed via a public-IP check from inside the pod (not just "the pod is Running").
- Whether hotio's images really do start cleanly as a non-root uid under `restricted` PSA, or need a fallback.
- Whether the cross-namespace NetworkPolicy between `arr-stack` and `arr-downloader` actually works (Sonarr successfully adding and monitoring a real download).
- Whether Kubernetes NetworkPolicy meaningfully constrains Gluetun's `tun0` traffic, or only its pre-tunnel `eth0` traffic.
- A real end-to-end pipeline run: Prowlarr synced to Sonarr/Radarr, a real download completing, and Sonarr/Radarr importing/hardlinking it into `/media/Movies` or `/media/TV Shows`.

Public exposure and prod deployment both stay deferred, matching every other app in this repo's rollout history.
