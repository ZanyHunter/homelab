# 4. Connect to the cluster

Run these commands from `tofu/live/dev/talos-cluster/` (or `tofu/live/<env>/talos-cluster/` for another environment) to download Talos and Kubernetes configuration files to the default locations:

```bash
terragrunt output -raw talosctl_config > ~/.talos/config
terragrunt output -raw kube_config > ~/.kube/config
```