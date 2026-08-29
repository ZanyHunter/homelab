locals {
  # The cluster's floating control-plane VIP, consumed by control-plane.yaml.tftpl.
  # Talos claims this address via etcd leader election once a control plane's etcd is
  # up, so it must NOT be used as the bootstrap-time endpoint below (see first_control_plane_ip).
  k8s_virtual_ip = var.cluster.endpoint
  # A real, already-reachable control-plane node IP for one-shot Terraform-provider
  # calls (bootstrap, kubeconfig fetch) that can't depend on the VIP existing yet.
  first_control_plane_ip = [for k, v in var.k8s_nodes : split("/", v.ip_address)[0] if v.role == "controlplane"][0]
  # Any Proxmox node running Ceph can dispatch the pool API call — the pool
  # itself is cluster-wide, not node-scoped. Reuses whichever Proxmox node
  # already hosts one of this cluster's VMs rather than a separately-listed
  # value, same reasoning as first_control_plane_ip above.
  ceph_dispatch_node = [for k, v in var.k8s_nodes : v.proxmox_node][0]
}

# A dedicated pool within the existing Proxmox Ceph cluster (ceph-1 datastore,
# already backing this cluster's own VM disks) — not new hardware, just a
# second logical namespace within the same disks/cluster. Kept separate from
# the pool VM disks live in so ceph-csi's CephX credential (core-addons) can
# be scoped to touch only this pool, not VM storage (#28).
resource "proxmox_ceph_pool" "k8s_rbd" {
  node_name = local.ceph_dispatch_node
  name      = var.ceph.pool_name

  application       = "rbd"
  size              = 3
  min_size          = 2
  pg_autoscale_mode = "on"
  # Don't also register this as a generic Proxmox VM-disk storage target —
  # this pool exists purely for Kubernetes RBD use via ceph-csi.
  add_storages = false
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
  cluster_name         = var.cluster.name
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
    cores = each.value.role == "controlplane" ? var.node_resources.controlplane.cores : var.node_resources.worker.cores
  }

  memory {
    dedicated = each.value.role == "controlplane" ? var.node_resources.controlplane.memory : var.node_resources.worker.memory
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
