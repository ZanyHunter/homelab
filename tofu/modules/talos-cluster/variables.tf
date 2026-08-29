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
