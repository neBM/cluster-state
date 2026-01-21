# Kubernetes Network Policies

This directory contains CiliumNetworkPolicy resources that control service-to-service communication.

These replace Consul service intentions from the Nomad cluster.

## Pattern

Network policies are typically defined within each service module (see `modules-k8s/echo/main.tf` for an example).

This directory is reserved for cluster-wide policies that apply across multiple services.

## Testing mTLS

After deploying Cilium with Hubble, you can verify mTLS is working:

```bash
# Open Hubble UI
cilium hubble ui

# Or use CLI
hubble observe --from-pod default/whoami --to-pod default/echo
```

## Default Deny (Optional)

To enable a zero-trust model where all traffic must be explicitly allowed:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: default
spec:
  endpointSelector: {}
  ingress:
    - {}
```

Note: Enable this only after all required policies are in place.
