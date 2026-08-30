# Deployed Apps

All hostnames below use `dev`'s domain suffix (`dev.thepugh.family`) — see [DNS and Ingress Hostnames](../explanation/dns-and-hostnames.md) for how the suffix is derived per environment, and the tabbed blocks on individual pages for the production form. None of the real apps below are publicly exposed today — see [Public Ingress via Cloudflare Tunnel](../explanation/public-ingress.md).

## Cluster add-ons

| App | Hostname | Auth | Notes |
| --- | --- | --- | --- |
| ArgoCD | `argocd.dev.thepugh.family` | Keycloak OIDC, `platform-admins` group | [SSO and Keycloak](../explanation/sso-and-keycloak.md) |
| Keycloak | `keycloak.dev.thepugh.family` | Local admin account | Internal/VPN-only, permanently — never gets a public tunnel route |
| Grafana | `grafana.dev.thepugh.family` | Keycloak OIDC, `platform-admins` group | [Observability](../explanation/observability.md) |
| sso-demo (`whoami`) | `sso-demo.dev.thepugh.family` | oauth2-proxy forward-auth | Living reference deployment, not a throwaway — the template for changedetection.io below |

## Real apps

| App | Hostname | Database | Storage | Auth |
| --- | --- | --- | --- | --- |
| [Immich](../explanation/immich.md) | `photos.dev.thepugh.family` | Postgres (VectorChord), `ceph-rbd-dev` | Media: `nfs-dev` | Keycloak OIDC (native) |
| [Actual Budget](../explanation/self-hosted-apps.md) | `actual.dev.thepugh.family` | SQLite (bundled) | 5Gi, `ceph-rbd-dev` | Keycloak OIDC (native) |
| [Paperless-ngx](../explanation/self-hosted-apps.md) | `paperless.dev.thepugh.family` | Postgres, `ceph-rbd-dev` (10Gi) | Media: `nfs-dev` (100Gi) | Keycloak OIDC (native), `platform-admins` → Django superuser |
| [Vaultwarden](../explanation/self-hosted-apps.md) | `vaultwarden.dev.thepugh.family` | SQLite (bundled) | 5Gi, `ceph-rbd-dev` | Keycloak OIDC (native, SSO-only) |
| [Homebox](../explanation/self-hosted-apps.md) | `inventory.dev.thepugh.family` | SQLite (bundled) | 2Gi, `ceph-rbd-dev` | Keycloak OIDC (native) |
| [changedetection.io](../explanation/self-hosted-apps.md) | `changedetection.dev.thepugh.family` | None (flat JSON) | 5Gi, `ceph-rbd-dev` | oauth2-proxy forward-auth |

To add another app, see the [Onboard a New App](../guides/onboard-a-new-app.md) guide.
