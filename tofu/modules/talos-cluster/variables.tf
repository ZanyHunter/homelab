variable "vlan_id" {
  type        = number
  description = "VLAN ID this cluster's VMs attach to — comes from the network unit's output, not a separately-supplied value, so there's a single source of truth for it."
}

variable "k8s_nodes" {
  type = map(object({
    proxmox_node  = string
    role          = string
    startup_order = optional(number)
    vm_id         = number
    ip_address    = string
  }))

  validation {
    condition = alltrue([
      for node in var.k8s_nodes : contains(["worker", "controlplane"], node.role)
    ])
    error_message = "`role` must be either `worker` or `controlplane`"
  }
}

variable "cluster" {
  type = object({
    name            = string
    endpoint        = string
    gateway         = string
    talos_version   = string
    proxmox_cluster = string
  })
}

variable "ceph" {
  description = "Config for the dedicated Ceph pool this environment's database workloads use (#28) — see tofu/live/dev/env.hcl's ceph block for where the values come from."
  type = object({
    pool_name  = string
    cluster_id = string
    monitors   = list(string)
  })
}

variable "node_resources" {
  description = "Per-role vCPU/memory sizing for this environment's Talos VMs. Split by role (not a single flat value) since control-plane nodes carry no scheduled workloads and stay small, while worker nodes need real headroom for whatever actually runs there — see tofu/live/dev/env.hcl's node_resources block."
  type = object({
    controlplane = object({
      cores  = number
      memory = number # MB
    })
    worker = object({
      cores  = number
      memory = number # MB
    })
  })
}
