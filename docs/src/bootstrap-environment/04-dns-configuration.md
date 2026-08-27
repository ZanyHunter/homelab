# 5. DNS Configuration

To access your ingress-routed applications (such as ArgoCD) using custom domain names (e.g., `argocd.k8s.thepugh.family`), you must configure local DNS name resolution.

Recent versions of the **UniFi Network Application** support wildcard hostnames directly in the UI. This allows you to resolve all subdomains under `k8s.thepugh.family` to the cluster's ingress controller using a single wildcard DNS entry.

---

## Step-by-Step Configuration

1. **Log in** to your UniFi Network Application dashboard.
2. Navigate to **Settings** > **Routing** > **DNS**.
3. Under the **Local DNS Records** section, click **Add**.
4. Configure the record details as follows:
   * **Host (Domain Name)**: `*.k8s.thepugh.family` (the asterisk `*` serves as the wildcard)
   * **IP Address**: `192.168.160.5` (the virtual LoadBalancer IP assigned to `ingress-nginx-controller`)
5. Click **Save**.

---

## Verification

To verify that name resolution is working correctly, run a query from a client machine on your network:

```bash
nslookup argocd.k8s.thepugh.family
```

It should return the Ingress controller's load balancer IP:

```text
Server:		192.168.0.1
Address:	192.168.0.1#53

Name:	argocd.k8s.thepugh.family
Address: 192.168.160.5
```

Any new service you deploy in the future under the `*.k8s.thepugh.family` domain will automatically resolve to your Ingress controller without requiring any additional DNS configuration.
