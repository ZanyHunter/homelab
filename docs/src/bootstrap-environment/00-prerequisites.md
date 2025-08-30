# Prerequisites

Prior to embarking on this journey, ensure you have the following infrastructure:

- Unifi-based network infrastructure exists, with the Network application running
- Proxmox infrastructure exists
    - Ideally, this cluster has a minimum of three physical nodes and uses Ceph to follow HCI principles.
    - Networking is configured to allow VLAN trunking
- NFS backend exists
    - For bulk storage of application data (e.g. Immich media, Plex media, etc.)

On your local bootstrap machine, ensure you have the following:

- Ubuntu
- OpenTofu
- This repo cloned
