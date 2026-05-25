# Phase 7: Observability (Optional)

> **Note:** User Workload Monitoring (UWM) was already configured in Phase 2 as a **required** component. UWM provides the foundational Prometheus scraping infrastructure that all other monitoring features depend on.

This phase adds **optional** observability enhancements on top of UWM:

1. **Cluster Observability Operator (COO)** -- required for the Observability Dashboard tab in the RHOAI UI. COO provides the Perses CRDs (`Perses`, `PersesDatasource`, `PersesDashboard`) that the RHOAI operator uses to deploy the dashboard backend.

2. **Gateway Telemetry** -- per-model, per-user, per-subscription usage metrics on the MaaS gateway. Adds fine-grained labels (`model`, `user`, `subscription`, `organization_id`, `cost_center`) to gateway metrics for usage attribution and billing.

## Step 1: Install the Cluster Observability Operator

```bash
oc apply -k 07-observability/coo/
```

Wait for the operator CSV to reach `Succeeded`:

```bash
oc get csv -n openshift-cluster-observability-operator -w
```

## Step 2: Apply Gateway Telemetry

Once COO is installed and the MaaS gateway is running:

```bash
oc apply -k 07-observability/telemetry/
```

## Verification

Check the COO operator is installed:

```bash
oc get csv -n openshift-cluster-observability-operator | grep cluster-observability-operator
# Expected: cluster-observability-operator   Succeeded
```

Check the Perses CRDs are registered:

```bash
oc get crd perses.perses.dev
```

Check the TelemetryPolicy exists:

```bash
oc get telemetrypolicies.extensions.kuadrant.io maas-telemetry -n openshift-ingress
```

Check the Istio Telemetry exists:

```bash
oc get telemetry.telemetry.istio.io latency-per-subscription -n openshift-ingress
```

## References

- [Cluster Observability Operator documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/monitoring/cluster-observability-operator)
- [RHOAI Observability dashboard](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2-latest/html/monitoring_data_science_models/index)
- [Kuadrant TelemetryPolicy](https://docs.kuadrant.io/latest/kuadrant-operator/doc/reference/telemetrypolicy/)
