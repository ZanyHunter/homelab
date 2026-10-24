# Resize Cluster Nodes

Node CPU/memory comes from `node_resources` in `tofu/live/<env>/env.hcl`. Changing it makes the Proxmox provider reboot each affected VM, and a plain `terragrunt apply` of `talos-cluster` reboots **all of them at once** — for control planes that takes down all three etcd members together and loses quorum. Apply one VM at a time instead, from `tofu/live/<env>/talos-cluster/`.

---

```bash
export KUBECONFIG=<kubeconfig for this environment>
terragrunt plan   # confirm only memory/cores changes on the nodes you expect

# Control planes: strictly one at a time. Worker nodes: cordon+drain each first (below).
for n in <ctrl-00> <ctrl-01> <ctrl-02>; do
  terragrunt apply -target="proxmox_virtual_environment_vm.nodes[\"$n\"]"
  kubectl wait --for=condition=Ready node/$n --timeout=10m
  # Don't move on until all three etcd members are back and the API is healthy
  kubectl get --raw='/readyz?verbose' | tail -3
done
```

Node names are the keys of `k8s_nodes` for that environment (see its `env.hcl`). For a worker, run `kubectl cordon <node> && kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` before its apply and `kubectl uncordon <node>` after it is `Ready`.

After the last node, run an untargeted `terragrunt plan` — it should show no changes.

Apply dev first and watch it for a day before touching prod; prod's `terragrunt` commands are run by the operator only.
