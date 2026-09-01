# Wikipedia Mirror (Kiwix)

An offline-capable reference mirror (#53), reachable at:

{{#tabs global="domain" }}
{{#tab name="Production" }}
`https://wikipedia.thepugh.family`
{{#endtab }}
{{#tab name="Development" }}
`https://wikipedia.dev.thepugh.family`
{{#endtab }}
{{#endtabs }}

[Kiwix](https://kiwix.org) (the ZIM file format + `kiwix-serve`) is the standard modern approach to this — simpler and lighter than a real MediaWiki + XML-dump mirror, and the one actively-maintained option of the three approaches surveyed (Nginx caching proxy, Kiwix, MediaWiki/XOWA). It gets its own page rather than folding into [Self-Hosted Apps](./self-hosted-apps.md), the same reasoning as [Immich](./immich.md): its shape is genuinely different from the SQLite/Postgres-plus-NFS pattern every other app in this repo follows — no database at all, no SSO, and a scheduled content-refresh mechanism unique to this app.

## Scope: what's actually mirrored

Kiwix publishes Wikipedia in three flavors — Maxi (full articles + images), nopic (full text, no images, ~40% of Maxi), and Mini (intro + infobox only, ~10% of Maxi). This deployment uses **Maxi**, plus a bundle of Wikimedia sibling projects Kiwix publishes on the same infrastructure — decided up front rather than growing the PVC ad hoc later, per real sizes verified against `download.kiwix.org`'s own metalink metadata at onboarding time (2026-08):

| Series | Edition | Size |
| --- | --- | --- |
| Wikipedia (English) | Maxi | ~124GB |
| Wikisource (English) | Maxi | ~20GB |
| Wiktionary (English) | nopic (no Maxi published) | ~9GB |
| Wikibooks (English) | Maxi | ~6GB |
| Wikivoyage (English) | Maxi | ~1GB |
| Wikiquote (English) | Maxi | ~1GB |

~162GB at rest. Project Gutenberg and Stack Exchange were deliberately left out of this bundle: both are structured very differently from the Wikimedia-family ZIMs above (Gutenberg splits into dozens of per-LCC-subject files, Stack Exchange is one file per site — `serverfault.com`, `superuser.com`, etc.) and would need their own scope decision rather than folding in blindly.

## No database, no Ceph, no backup

The whole app is a single **NFS-backed** PVC (`wikipedia-data`, 320Gi) holding the ZIM files plus `kiwix-serve`'s `library.xml` — no Ceph-backed component at all, the first app in this repo's `apps/` tree with no database. 320Gi isn't just the ~162GB steady-state total: the update mechanism (below) downloads a series' new release fully before deleting the old one, so during a Wikipedia Maxi update specifically — the largest series — old and new briefly coexist, pushing peak usage to ~286GB. 320Gi leaves headroom above that peak for future release growth too.

ZIM files are trivially re-downloadable from `download.kiwix.org`'s public mirror if ever lost, so unlike every other app in this repo, this one gets **no Velero File System Backup annotation** — there's no Ceph-backed volume to annotate in the first place, and re-downloading is strictly simpler than restoring from backup. Treat this app's data as a re-fetchable cache, not source-of-truth data.

## No SSO, no public exposure

`kiwix-serve` has no auth of its own and no OIDC support. Rather than bolt on `oauth2-proxy` forward-auth for its own sake, this is left open on LAN/VPN — a deliberate judgment call, not a gap: the content is public-domain and low-sensitivity.

It's also **not** in `public_apps` (see [Public Ingress via Cloudflare Tunnel](./public-ingress.md)) and isn't a candidate for it later, unlike the rest of this repo's apps: serving 100GB+ of content to the public internet is a real bandwidth/cost consideration distinct from every other app here, flagged explicitly rather than defaulting to "expose if desired."

## Keeping content current: the updater CronJob

Kiwix publishes dated snapshots (`..._2026-02.zim`), not continuously updated content, and release cadence differs per series — Wikipedia Maxi roughly every 6 months, the smaller Wikimedia-sibling series more like every 1-3 months, per the dated filenames observed at onboarding time. A `CronJob` (`wikipedia-updater`, monthly — comfortably ahead of every series' cadence without checking so often that most runs do nothing) keeps the bundle current, alternating two containers **per series** (twelve `initContainers` plus one final main container, not one big download pass followed by a single reindex — see the gotcha below on why):

1. **`sync-one` (`curlimages/curl`)**: for one series (its category and filename prefix passed as arguments), lists `download.kiwix.org`'s directory for that category, compares the newest dated filename against what's already on the PVC, and downloads it if newer — verifying the downloaded size against the release's own `.meta4` metalink metadata before an atomic `mv` into place. Never exits non-zero: a failure (a transient blip on the ~124GB Wikipedia file, say) doesn't stop that series' own `reindex` step from running on whatever *did* download before it, and doesn't stop the next series' pair from running either. A failed/incomplete series is simply retried on the next scheduled run.
2. **`reindex` (`ghcr.io/kiwix/kiwix-tools`)**: rebuilds `library.xml` from scratch from whatever `*.zim` files are currently on the PVC (via `kiwix-manage add`, not an incremental add/remove-by-ID), then deletes any now-superseded dated file per series. Idempotent by construction — safe to run with zero ZIM files present, safe to re-run after every single series in the sequence.

`kiwix-serve` itself runs with `--library --monitorLibrary /data/library.xml`, so a rebuilt `library.xml` is picked up live — **no pod restart needed** on every content refresh (verified live: an atomic `mv` replacing the file produces a second "The library was successfully loaded" line in `kiwix-serve`'s own logs, moments later, with no restart).

Splitting the download step into its own container also scopes the NetworkPolicy tightly: only pods labeled `app: wikipedia-updater` (the CronJob's pods) get an egress allowance to the open internet on 443. `download.kiwix.org` redirects (via `mirrorbrain`) to whichever geo-local partner mirror is closest, so this can't be pinned to a fixed CIDR the way an internal dependency could be — the always-on `kiwix-serve` Deployment never gets outbound internet access at all, keeping that blast radius as small as it can be.

The Deployment runs the same `reindex` logic as its own init container (a single call, since there's no download involved there), so `library.xml` always exists by the time `kiwix-serve` starts — including on the very first deploy, before the CronJob has ever run.

## Four real gotchas found live deploying Kiwix

- **`kiwix-serve`'s own Docker wrapper already adds `--port`.** The official `ghcr.io/kiwix/kiwix-serve` image's entrypoint (`start.sh`) always prepends `--port=$PORT` (default `8080`) to whatever arguments it's given. Passing `--port=8080` again in the Deployment's `args` produced a literal `kiwix-serve --port=8080 --port=8080 ...` and an `Unexpected argument` crash-loop — found live, fixed by dropping `--port` entirely from `args` and letting the wrapper supply it.
- **`--monitorLibrary` doesn't wait for the library file to appear — it refuses to start without one.** Verified live: `kiwix-serve --library --monitorLibrary /data/library.xml` exits (cleanly, exit code 0, but exits) if `/data/library.xml` doesn't exist at all yet, rather than idling until the file is created. This is exactly the state a fresh deploy is in before the updater `CronJob` has ever run — solved by giving the Deployment its own `reindex` init container (see above) so a valid `library.xml` (even an empty one, confirmed to start `kiwix-serve` cleanly) always exists first.
- **Cross-container writes to the shared PVC need a matching `fsGroup`, not just root-squash-disabled NFS.** The `sync-one` container (`curlimages/curl`'s own non-root default, uid 100/gid 101) got a real `Permission denied` writing to `/data` on its first live run, even though this repo's NFS exports already have root-squash disabled. Root-squash-disabled only changes how the NFS server treats *root* (uid 0) requests — it doesn't waive normal Unix permission checks between two different *non-root* uids. The PVC's root directory had already been created `drwxrwsr-x root:user` (setgid, group 1001) by the Deployment's own `reindex` init container (which runs as uid/gid 1001, via its pod's `fsGroup: 1001`) being the first pod to ever touch the volume — `curl_user` (uid 100, group 101) was in neither the owning user nor the owning group, so the setgid directory's `rwx` for group and `r-x` for other left it with no write access at all. Fixed by adding `fsGroup: 1001` to the CronJob pod's own `securityContext` too, so group 1001 becomes a supplementary group there as well, regardless of which container's uid actually does the writing.
- **One reindex at the end of all six series leaves already-finished series unsearchable for hours.** The first version of this `CronJob` ran one `download` init container that looped over all six series, followed by a single `reindex` main container at the very end. Live, this meant Wikiquote and Wikivoyage (both under ~1GB, finished downloading within the first two minutes) sat fully downloaded and completely unindexed on the PVC for the entire remainder of the run, while the ~124GB Wikipedia Maxi file was still in flight — `kiwix-serve`'s search returned "No result" for content that was, in fact, already sitting right there on disk. Restructured into a `sync-one`/`reindex` pair per series (see above) so each series becomes searchable within seconds of its own download finishing, independent of how long any other series takes.

## Verification

Verified live on dev: the Deployment reaches `1/1 Running` with an empty `library.xml` written by its own init container (confirmed via container logs matching a local Docker reproduction exactly), the Ingress/TLS certificate come up cleanly (`kubectl get certificate` `READY: True`, a real `HTTP 200` from the hostname), and a manually-triggered run of the updater `CronJob` downloaded full series (Wikiquote and Wikivoyage) with a passing size check against their `.meta4` metadata and a correct atomic rename into place. After hitting and fixing the reindex-timing gotcha above, re-verified that `library.xml` genuinely updates per series rather than only at the end: `curl`ing `kiwix-serve`'s own `/catalog/v2/entries` endpoint after just the first two series finished showed both titles present, and `kiwix-serve`'s logs showed two separate "The library was successfully loaded" reloads — proving content becomes searchable incrementally, not just that the mechanism runs at all. The full initial bundle download (~162GB across all six series) continues in the background past this verification pass.
