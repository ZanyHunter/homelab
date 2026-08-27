output "talosctl_config" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "kube_config" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "machine_config" {
  value     = data.talos_machine_configuration.this
  sensitive = true
}

# Consumed by every downstream unit to build its own kubernetes/helm provider
# blocks (dependency.talos_cluster.outputs.kubernetes_client_configuration.*)
# — same attributes tofu/providers.tf used to read directly off
# talos_cluster_kubeconfig.this before the unit split.
output "kubernetes_client_configuration" {
  value     = talos_cluster_kubeconfig.this.kubernetes_client_configuration
  sensitive = true
}
