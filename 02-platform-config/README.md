# Phase 2: Platform Configuration

This phase configures the platform prerequisites for MaaS: Kuadrant/Authorino
(auth and rate limiting), User Workload Monitoring, the GatewayClass, and the
MaaS Gateway.

Apply each step in order and wait for the status gates before proceeding to the
next step. The ordering matters because later resources depend on earlier ones
(e.g. the Authorino CR references the TLS cert created by the Service
annotation, and the Gateway requires the GatewayClass to exist).

## Prerequisites

- OpenShift 4.17+ cluster with `oc` CLI authenticated as cluster-admin
- Red Hat Connectivity Link (RHCL) operator already installed
  (see [RHCL docs](https://docs.redhat.com/en/documentation/red_hat_connectivity_link))
- Phase 1 (operators) completed

## Step 1: Kuadrant and Authorino

Apply the namespace, service annotation, and Kuadrant CR. Do **not** apply the
full kustomization in one shot — the Kuadrant operator auto-creates an Authorino
CR when it reconciles the Kuadrant resource, so the Authorino CR must be
configured separately via `oc patch` after Kuadrant is ready.

```bash
oc apply -f 02-platform-config/kuadrant/namespace.yaml
oc apply -f 02-platform-config/kuadrant/service-annotation.yaml
oc apply -f 02-platform-config/kuadrant/kuadrant.yaml
```

Wait for Kuadrant to become ready:

```bash
oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=120s
```

> **Troubleshooting:** If Kuadrant reports `MissingDependency` (Istio race
> condition), restart the Kuadrant operator pod and wait again:
>
> ```bash
> oc delete pod -n openshift-operators \
>   $(oc get pods -n openshift-operators --no-headers | grep kuadrant-operator | awk '{print $1}')
> oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=180s
> ```

## Step 2: Configure TLS for Models-as-a-Service

Follow [RHOAI 3.4 docs section 1.4](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas#configure-tls-for-maas_maas-deploy) — four steps to enable TLS between the Gateway and Authorino.

**Step 2a:** The service annotation (already applied above) triggers the
service-ca operator to generate the `authorino-server-cert` TLS Secret:

```bash
oc get secret authorino-server-cert -n kuadrant-system
```

**Step 2b:** Patch the Authorino CR to enable the TLS listener:

```bash
oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": {
          "name": "authorino-server-cert"
        }
      }
    }
  }
}'
```

**Step 2c:** Configure Authorino deployment with TLS certificate env vars:

```bash
oc -n kuadrant-system set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
```

Wait for the Authorino deployment to become available:

```bash
oc wait --for=condition=Available deployment/authorino -n kuadrant-system --timeout=300s
```

## Step 2: User Workload Monitoring (UWM)

Enable User Workload Monitoring so that Prometheus scrapes MaaS and Kuadrant
metrics from user namespaces.

```bash
oc apply -k 02-platform-config/uwm/
```

Wait for the user-workload monitoring stack to start:

```bash
oc wait --for=condition=Available deployment/prometheus-operator \
  -n openshift-user-workload-monitoring --timeout=300s
```

Verify the Prometheus pods are running:

```bash
oc get pods -n openshift-user-workload-monitoring
```

You should see `prometheus-user-workload-0` and `thanos-ruler-user-workload-0`
pods in Running state.

## Step 3: GatewayClass

Apply the GatewayClass that initializes OpenShift's built-in Gateway API
controller:

```bash
oc apply -f 02-platform-config/gatewayclass.yaml
```

Wait for the GatewayClass to be accepted:

```bash
oc wait --for=condition=Accepted gatewayclass/openshift-default --timeout=120s
```

Verify:

```bash
oc get gatewayclass openshift-default
```

Expected output:

```
NAME                CONTROLLER                           ACCEPTED   AGE
openshift-default   openshift.io/gateway-controller/v1   True       ...
```

## Step 4: MaaS Gateway

The Gateway uses cluster-specific values (domain and TLS cert name), so it is
provided as an envsubst template. Detect the values, render the template, and
apply.

Detect the cluster domain and TLS certificate name:

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')

export CERT_NAME=$(oc get ingresscontroller default \
  -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
[ -z "$CERT_NAME" ] && export CERT_NAME="router-certs-default"
```

Render and apply:

```bash
envsubst '${CLUSTER_DOMAIN} ${CERT_NAME}' < 02-platform-config/gateway.yaml.tmpl | oc apply -f -
```

**Step 2d:** Annotate the Gateway for Authorino TLS bootstrap (docs section 1.4, step 4):

```bash
oc annotate gateway maas-default-gateway -n openshift-ingress \
  security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite
```

Wait for the Gateway to be programmed:

```bash
oc wait --for=condition=Programmed gateway/maas-default-gateway \
  -n openshift-ingress --timeout=120s
```

> **Non-cloud clusters (baremetal/OpenStack):** If the Gateway stays in
> `AddressNotAssigned` because no cloud load-balancer provisions an external IP,
> create a passthrough Route as a fallback:
>
> ```bash
> envsubst '${CLUSTER_DOMAIN}' < 04-maas-platform/openshift-gateway-setup/route.yaml.tmpl | oc apply -f -
> ```
>
> This routes traffic through the existing OpenShift ingress controller. See
> [OpenShift Gateway Setup](../04-maas-platform/openshift-gateway-setup/README.md)
> for MetalLB-based alternatives.

Verify:

```bash
oc get gateway maas-default-gateway -n openshift-ingress
```

## Verification

After completing all four steps, confirm the full platform state:

```bash
# Kuadrant ready
oc get kuadrant -n kuadrant-system

# Authorino running with TLS
oc get deployment authorino -n kuadrant-system
oc get secret authorino-server-cert -n kuadrant-system

# UWM running
oc get pods -n openshift-user-workload-monitoring

# GatewayClass accepted
oc get gatewayclass openshift-default

# Gateway programmed
oc get gateway maas-default-gateway -n openshift-ingress
```

## References

- [MaaS Platform Setup (upstream)](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/platform-setup.md)
- [MaaS Gateway Setup (upstream)](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/maas-setup.md)
- [Red Hat Connectivity Link documentation](https://docs.redhat.com/en/documentation/red_hat_connectivity_link)
- [OpenShift User Workload Monitoring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/monitoring/enabling-monitoring-for-user-defined-projects)
- [Gateway API on OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/networking/gateway-api)

## Next Steps

Proceed to [Phase 3: RHOAI Configuration](../03-rhoai-config/README.md).
