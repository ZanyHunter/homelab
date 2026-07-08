# 2. Prepare Infrastructure

1. Create role and user in Proxmox for Tofu:
    ```
    pveum role add TerraformProv -privs "Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Sys.Audit Sys.Console Sys.Modify VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.GuestAgent.Audit VM.GuestAgent.Unrestricted VM.Migrate VM.PowerMgmt SDN.Use"
    pveum user add terraform-prov@pve --password <password>
    pveum aclmod / -user terraform-prov@pve -role TerraformProv
