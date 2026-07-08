# 3. Deploy Kubernetes Cluster

Now that the infrastructure is prepared, deploy the cluster.

1. `cd tofu`
1. Modify variables in `nodes.auto.tfvars` if necessary
1. Run:
    ```bash
    tofu init
    tofu apply
    ```

## Concepts

This Tofu configuration:

1. Creates a network for the Kubernetes cluster to reside
1. Downloads the appropriate Talos ISO onto each physical node where Kubernetes will be hosted