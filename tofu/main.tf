locals {
  # Calculate total number of usable IPs (excluding network and broadcast)
  total_k8s_ips = pow(2, 32 - tonumber(split("/", var.network_cidr)[1])) - 2
  # The cluster's floating control-plane VIP, consumed by control-plane.yaml.tftpl.
  # Talos claims this address via etcd leader election once a control plane's etcd is
  # up, so it must NOT be used as the bootstrap-time endpoint below (see first_control_plane_ip).
  k8s_virtual_ip = var.cluster.endpoint
  # Generate list of usable IPs
  usable_k8s_ips = [for i in range(2, local.total_k8s_ips + 1) : cidrhost(var.network_cidr, i)]
  # A real, already-reachable control-plane node IP for one-shot Terraform-provider
  # calls (bootstrap, kubeconfig fetch) that can't depend on the VIP existing yet.
  first_control_plane_ip = [for k, v in var.k8s_nodes : split("/", v.ip_address)[0] if v.role == "controlplane"][0]
}

resource "unifi_network" "this" {
  name         = "K8s-Cluster-Prod"
  purpose      = "corporate"
  dhcp_enabled = false
  # dhcp_lease = 3600
  # dhcp_start = cidrhost(var.network_cidr, 2)
  # dhcp_stop = cidrhost(var.network_cidr, local.total_k8s_ips)

  domain_name = "k8s.thepugh.family"
  # internet_access_enabled = false
  # network_isolation_enabled = true
  subnet  = var.network_cidr
  vlan_id = var.vlan_id
}

data "talos_image_factory_extensions_versions" "this" {
  talos_version = var.cluster.talos_version
  filters = {
    names = [
      "nut-client",
      "qemu-guest-agent",
    ]
  }
}

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode(
    {
      customization = {
        systemExtensions = {
          officialExtensions = data.talos_image_factory_extensions_versions.this.extensions_info.*.name
        }
      }
    }
  )
}

data "talos_image_factory_urls" "this" {
  talos_version = var.cluster.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "nocloud"
}

# Download the image to each proxmox node
resource "proxmox_virtual_environment_download_file" "iso" {
  for_each = toset(distinct([
    for _, obj in var.k8s_nodes : obj.proxmox_node
  ]))

  node_name    = each.value
  datastore_id = "local"
  url          = data.talos_image_factory_urls.this.urls.iso
  content_type = "iso"
}

# Generate CA certificates and related secrets
resource "talos_machine_secrets" "this" {
  talos_version = var.cluster.talos_version
}

data "talos_client_configuration" "this" {
  cluster_name         = "dev"
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = [for k, v in var.k8s_nodes : split("/", v.ip_address)[0]]
  endpoints            = [for k, v in var.k8s_nodes : split("/", v.ip_address)[0] if v.role == "controlplane"]
}

data "talos_machine_configuration" "this" {
  for_each         = var.k8s_nodes
  cluster_name     = var.cluster.name
  cluster_endpoint = "https://${var.cluster.endpoint}:6443"
  talos_version    = var.cluster.talos_version
  machine_type     = each.value.role
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  config_patches = each.value.role == "controlplane" ? [
    templatefile("${path.module}/control-plane.yaml.tftpl", {
      hostname     = each.key
      node_name    = each.value.proxmox_node
      cluster_name = var.cluster.proxmox_cluster
      image        = data.talos_image_factory_urls.this.urls.installer
      vip_ip       = local.k8s_virtual_ip
    })
    ] : [
    templatefile("${path.module}/worker.yaml.tftpl", {
      hostname     = each.key
      node_name    = each.value.proxmox_node
      cluster_name = var.cluster.proxmox_cluster
    })
  ]
}

# Create Talos VMs for each node
resource "proxmox_virtual_environment_vm" "nodes" {
  for_each = var.k8s_nodes

  name      = each.key
  node_name = each.value.proxmox_node
  on_boot   = true
  vm_id     = each.value.vm_id
  # agent {
  #   enabled = true
  # }
  cdrom {
    file_id = proxmox_virtual_environment_download_file.iso[each.value.proxmox_node].id
  }

  cpu {
    type  = "x86-64-v2-AES"
    cores = 4
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = "ceph-1"
    interface    = "scsi0"
    # iothread     = true
    cache       = "writeback"
    discard     = "on"
    ssd         = true
    file_format = "raw"
    size        = 20
    # file_id      = proxmox_virtual_environment_download_file.iso[each.value.proxmox_node].id
  }

  scsi_hardware = "virtio-scsi-single"

  boot_order = [
    "scsi0",
    "ide3"
  ]

  network_device {
    vlan_id = var.vlan_id
    model   = "virtio"
    mtu     = 1400
  }

  startup {
    order = each.value.startup_order
  }

  initialization {
    datastore_id = "ceph-1"
    ip_config {
      ipv4 {
        address = each.value.ip_address
        gateway = var.cluster.gateway
      }
    }
  }

  # depends_on = [unifi_network.this]
}

resource "talos_machine_configuration_apply" "this" {
  depends_on = [proxmox_virtual_environment_vm.nodes]
  for_each   = var.k8s_nodes

  node                        = split("/", each.value.ip_address)[0]
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this[each.key].machine_configuration
  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_vm.nodes[each.key]]
  }
}

resource "talos_machine_bootstrap" "this" {
  node                 = local.first_control_plane_ip
  endpoint             = local.first_control_plane_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_configuration_apply.this]
}

data "talos_cluster_health" "this" {
  depends_on = [
    talos_machine_configuration_apply.this,
    talos_machine_bootstrap.this
  ]
  client_configuration = data.talos_client_configuration.this.client_configuration
  control_plane_nodes  = [for k, v in var.k8s_nodes : split("/", v.ip_address)[0] if v.role == "controlplane"]
  worker_nodes         = [for k, v in var.k8s_nodes : split("/", v.ip_address)[0] if v.role == "worker"]
  endpoints            = data.talos_client_configuration.this.endpoints
  timeouts = {
    read = "10m"
  }
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on = [
    talos_machine_bootstrap.this,
    data.talos_cluster_health.this
  ]
  node                 = local.first_control_plane_ip
  endpoint             = local.first_control_plane_ip
  client_configuration = talos_machine_secrets.this.client_configuration
  timeouts = {
    read = "1m"
  }
}

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