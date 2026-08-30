# Grant Platform-Admin Access

ArgoCD and Grafana both gate admin access on membership in a `platform-admins` Keycloak group, not any hardcoded person's identity — see [SSO and Keycloak](../explanation/sso-and-keycloak.md) for why. Group membership isn't Tofu-managed; it's done by hand in Keycloak's admin console.

---

Open Keycloak's admin console:

{{#tabs global="domain" }}
{{#tab name="Production" }}
`https://keycloak.thepugh.family`
{{#endtab }}
{{#tab name="Development" }}
`https://keycloak.dev.thepugh.family`
{{#endtab }}
{{#endtabs }}

(admin credentials: `kubectl get secret -n keycloak keycloak-admin-credentials -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d`)

1. Create (or open an existing) user account for the person.
2. On that account, go to the **Groups** tab → **Join Group** → `platform-admins`.
3. Have them log out and back in to ArgoCD/Grafana (or any other app whose RBAC checks this group) — the `groups` claim is evaluated fresh on login.

To revoke access, remove them from the group the same way.
