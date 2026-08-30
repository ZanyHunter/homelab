# Remote Tofu State

Tofu's state lives under `tofu/state/` — a gitignored directory meant to be an SMB mount of a share on the NAS, set up out-of-band, outside of Tofu entirely (see the [Deploy From Scratch](../guides/deploy-from-scratch.md) guide for the one-time mount step on a new machine). Since the [Terragrunt refactor](./terragrunt-units.md), it's no longer one flat state file: each unit gets its own, at a path Terragrunt computes from directory structure rather than a single hand-typed literal.

```
tofu/state/
  dev/
    network/terraform.tfstate
    talos-cluster/terraform.tfstate
    core-addons/terraform.tfstate
    backup/terraform.tfstate
    keycloak-infra/terraform.tfstate
    observability/terraform.tfstate
    keycloak-realm/terraform.tfstate
  prod/
    ... (same shape, once prod is ever actually applied)
```

`tofu/live/root.hcl`'s `remote_state` block generates each unit's `backend "local"` with `path = "${get_repo_root()}/tofu/state/${path_relative_to_include()}/terraform.tfstate"` — `path_relative_to_include()` resolves to e.g. `dev/talos-cluster`, so nothing is hand-typed per unit, and a real `prod` environment gets its own state tree automatically the moment it's ever applied.

---

## Locking

Tofu's `local` backend locks state via `flock()`; Linux's CIFS client translates that into an SMB byte-range lock by default, which is what actually prevents two concurrent applies to the *same unit* from corrupting its state. **Never mount with the `nobrl` option** — it disables that translation and silently turns off locking. (Two different units never contend for the same lock regardless, since each has its own state file.)

## Why the earlier MinIO/S3 approach was abandoned

An earlier version of this remote state used a MinIO bucket hosted on this same cluster, with OpenTofu's native S3 conditional-write locking. It worked, including a real verified concurrent-apply lock test — but had a structural problem: MinIO was created *by* this Tofu config, so destroying the cluster would eventually destroy the very thing backing its own state, and the final state-persist write would fail as a result (a well-documented Terraform/Terragrunt anti-pattern: destroying infra that backs your own remote-state backend, through that same backend). SMB-on-the-NAS avoids this entirely — nothing this config creates or destroys can ever take its own state backend down with it, for `dev`, a future `prod`, or any other cluster this config might stand up. See git history for the full MinIO-based version if ever useful for comparison.

## Migrating existing state after a refactor

Splitting one state file into several (as the Terragrunt refactor did) is a `tofu state mv` operation per resource, done with the old backend's file as `-state` and the new unit's fresh state file as `-state-out` — no infrastructure changes, verified with `terragrunt run --all plan` showing zero changes before ever touching real infra. Not something expected to happen often, but the general technique for any future unit reshuffling.
