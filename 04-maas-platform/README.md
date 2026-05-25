# Phase 4: MaaS Platform Infrastructure

Deploy the PostgreSQL database and configure Authorino TLS for the MaaS platform.

## Prerequisites

- Phase 3 (RHOAI configuration) is applied
- DataScienceCluster has `modelsAsService: Managed`
- KserveReady and ModelControllerReady conditions are True on the DSC

## Overview

The MaaS platform requires:

1. **PostgreSQL database** -- stores API key metadata (hashed tokens, subscription
   bindings, expiration, revocation state). maas-api crash-loops until the DB is
   reachable and schema migration completes.
2. **PostgreSQL secrets** -- `postgres-creds` (DB credentials) and `maas-db-config`
   (connection URL consumed by maas-api).
3. **MaaS Gateway** -- Gateway API resource for inference traffic routing.
4. **Authorino TLS** -- TLS configuration between the Gateway and Authorino for
   auth policy enforcement.

## Quick start (automated)

The `scripts/setup-maas.sh` script handles all of the above (secrets, PostgreSQL,
Gateway, Authorino TLS) in a single command:

```bash
./scripts/setup-maas.sh
```

## Manual setup

### Step 1: Create PostgreSQL secrets

These secrets cannot be stored in git. Create them imperatively:

```bash
# Generate a random password
POSTGRES_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')

# Create postgres-creds (consumed by the PostgreSQL deployment)
oc create secret generic postgres-creds \
  -n redhat-ods-applications \
  --from-literal=POSTGRES_USER=maas \
  --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  --from-literal=POSTGRES_DB=maas

# Create maas-db-config (consumed by maas-api)
oc create secret generic maas-db-config \
  -n redhat-ods-applications \
  --from-literal=DB_CONNECTION_URL="postgresql://maas:${POSTGRES_PASSWORD}@postgres:5432/maas?sslmode=disable"
```

### Step 2: Deploy PostgreSQL

Apply the PostgreSQL manifests using Kustomize:

```bash
oc apply -k 04-maas-platform/
```

Or apply individually:

```bash
oc apply -f 04-maas-platform/postgres-pvc.yaml
oc apply -f 04-maas-platform/postgres-service.yaml
oc apply -f 04-maas-platform/postgres-deployment.yaml
```

### Step 3: Create the MaaS Gateway

Detect cluster domain and TLS certificate, then create the Gateway:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
CERT_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
CERT_NAME=${CERT_NAME:-router-certs-default}

oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: maas-default-gateway
  namespace: openshift-ingress
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
spec:
  gatewayClassName: openshift-default
  listeners:
    - name: http
      hostname: maas.${CLUSTER_DOMAIN}
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      hostname: maas.${CLUSTER_DOMAIN}
      port: 443
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: All
      tls:
        certificateRefs:
          - group: ""
            kind: Secret
            name: ${CERT_NAME}
        mode: Terminate
EOF
```

### Step 4: Configure Authorino TLS

Set environment variables on the Authorino deployment so it uses TLS when
communicating with the Gateway:

```bash
AUTHORINO_NS="rh-connectivity-link"

oc set env deployment/authorino -n "${AUTHORINO_NS}" \
  AUTHORINO_OPA_ENABLED=false \
  SSL_CERTS_DIR=/etc/ssl/certs
```

### (Optional) Baremetal/OpenStack gateway setup

If your cluster does not have a cloud load-balancer controller and the Gateway
LoadBalancer service stays in Pending, see:

```
04-maas-platform/openshift-gateway-setup/README.md
```

This provides MetalLB configuration and OpenShift Route templates for
environments without cloud LB support.

## Verify

### PostgreSQL

```bash
# Wait for PostgreSQL pod to be ready
oc wait --for=condition=Available deployment/postgres \
  -n redhat-ods-applications --timeout=120s

# Confirm the pod is running
oc get pods -n redhat-ods-applications -l app=postgres
```

### PostgreSQL secrets

```bash
# Verify both secrets exist
oc get secret postgres-creds -n redhat-ods-applications
oc get secret maas-db-config -n redhat-ods-applications
```

### maas-api

Once PostgreSQL is running and the `maas-db-config` secret exists, maas-api
should stop crash-looping and become ready:

```bash
oc rollout status deployment/maas-api -n redhat-ods-applications --timeout=120s
```

### Gateway

```bash
oc wait --for=condition=Programmed gateway/maas-default-gateway \
  -n openshift-ingress --timeout=60s
```

### Authorino TLS

```bash
# Verify env vars are set on the Authorino deployment
oc get deployment authorino -n rh-connectivity-link \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq .
```

### Tenant CR

The maas-controller auto-creates a `default-tenant` CR in the
`models-as-a-service` namespace:

```bash
oc get tenant default-tenant -n models-as-a-service
```

### MaaS health endpoint

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
curl -sk "https://maas.${CLUSTER_DOMAIN}/maas-api/health"
# 200 = healthy
```

## What this creates

| Resource | Namespace | Purpose |
|----------|-----------|---------|
| `PVC/postgres-data` | redhat-ods-applications | 20Gi storage for PostgreSQL data |
| `Service/postgres` | redhat-ods-applications | ClusterIP service for PostgreSQL |
| `Deployment/postgres` | redhat-ods-applications | PostgreSQL 16 instance (RHEL 9 based) |
| `Secret/postgres-creds` | redhat-ods-applications | DB user, password, database name (imperative) |
| `Secret/maas-db-config` | redhat-ods-applications | Connection URL for maas-api (imperative) |
| `Gateway/maas-default-gateway` | openshift-ingress | Gateway API entry point for MaaS (imperative) |

## Troubleshooting

### PostgreSQL pod not starting

```bash
oc describe pod -n redhat-ods-applications -l app=postgres
oc logs -n redhat-ods-applications -l app=postgres
```

Common causes:
- `postgres-creds` secret does not exist (create it per Step 1)
- PVC cannot be bound (check StorageClass availability)

### maas-api crash-looping

```bash
oc logs deployment/maas-api -n redhat-ods-applications --tail=50
```

Common causes:
- `maas-db-config` secret does not exist
- PostgreSQL is not yet ready
- Connection URL has incorrect credentials

### Gateway stuck in Pending

On baremetal/OpenStack clusters without a cloud LB controller:
- See `openshift-gateway-setup/` for MetalLB configuration
- On cloud clusters, the LB provisions automatically

## Next step

Proceed to Phase 5 (05-maas-models/) to deploy inference models.
