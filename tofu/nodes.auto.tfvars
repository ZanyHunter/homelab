network_cidr = "192.168.160.0/27"
vlan_id      = 1601

cluster = {
  name = "dev"
  # Floating control-plane VIP (Talos-managed, not any single node's address) — see
  # main.tf's local.k8s_virtual_ip. Lives in the range the /27 expansion freed up.
  endpoint        = "192.168.160.16"
  gateway         = "192.168.160.1"
  talos_version   = "v1.12.0"
  proxmox_cluster = "homelab"
}

chart_versions = {
  metallb        = "0.14.8"
  ingress_nginx  = "4.11.2"
  cert_manager   = "1.15.1"
  argocd         = "7.3.7"
  csi_driver_nfs = "4.13.4"
}

nfs_storage = {
  server = "truenas.thepugh.family"
  share  = "/mnt/Main/k8s-dev"
}

k8s_nodes = {
  "k8s-ctrl-00" = {
    proxmox_node  = "pve-node-0"
    role          = "controlplane"
    startup_order = "3"
    vm_id         = 16010
    ip_address    = "192.168.160.2/27"
  },
  "k8s-ctrl-01" = {
    proxmox_node  = "pve-node-1"
    role          = "controlplane"
    startup_order = "4"
    vm_id         = 16011
    ip_address    = "192.168.160.3/27"
  },
  "k8s-ctrl-02" = {
    proxmox_node  = "pve-node-2"
    role          = "controlplane"
    startup_order = "5"
    vm_id         = 16012
    ip_address    = "192.168.160.4/27"
  },
  "k8s-node-00" = {
    proxmox_node  = "pve-node-0"
    role          = "worker"
    startup_order = "6"
    vm_id         = 16013
    ip_address    = "192.168.160.9/27"
  },
  "k8s-node-01" = {
    proxmox_node  = "pve-node-1"
    role          = "worker"
    startup_order = "7"
    vm_id         = 16014
    ip_address    = "192.168.160.10/27"
  },
  "k8s-node-02" = {
    proxmox_node  = "pve-node-2"
    role          = "worker"
    startup_order = "8"
    vm_id         = 16015
    ip_address    = "192.168.160.11/27"
  }
}
