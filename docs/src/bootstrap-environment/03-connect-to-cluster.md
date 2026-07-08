# 4. Connect to the cluster

Run these commands to download Talos and Kubernetes configuration files to the default locations:

```bash
tofu output -raw talosctl_config > ~/.talos/config
tofu output -raw kube_config > ~/.kube/config
```