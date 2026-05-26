#!/usr/bin/env bash
#
# setup-maas.sh - End-to-end MaaS (Models as a Service) deployment on RHOAI
#
# Orchestrates the full MaaS lifecycle from a bare OpenShift cluster:
#   Phase 0: Preflight  - detect cluster state, decide which phases to run
#   Phase 1: Operators  - install required operator subscriptions
#   Phase 2: Platform config  - Kuadrant, UWM, GatewayClass, Gateway
#   Phase 3: RHOAI config  - DataScienceCluster, DSCInitialization, Dashboard
#   Phase 4: MaaS platform  - PostgreSQL secrets/deployment, Authorino TLS
#   Phase 5: Deploy model  - auto-detect GPU, apply model Kustomize
#   Phase 6: Verify  - run 6-phase E2E verification
#   Phase 7: Observability (optional)  - COO + Gateway telemetry
#
# Each phase is idempotent  - re-running skips what's already done.
#
# Usage:
#   ./scripts/setup-maas.sh [OPTIONS]
#
# Options:
#   --model <name>       Model: simulator, granite-tiny-gpu, gpt-oss-20b, auto (default: auto)
#   --from-phase <N>     Start from phase N (default: 0)
#   --skip-models        Skip Phase 5 (model deployment)
#   --skip-verify        Skip Phase 6 (verification)
#   --with-observability Also run Phase 7 (COO + telemetry)
#   --dry-run            Preview without applying
#   -h, --help           Show this help message
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUIDE_DIR="$SCRIPT_DIR/.."
NAMESPACE=redhat-ods-applications

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_phase() { echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════${NC}"; echo -e "${BOLD}${BLUE}  Phase $1: $2${NC}"; echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"; }

MODEL="auto"
FROM_PHASE=0
SKIP_MODELS=false
SKIP_VERIFY=false
WITH_OBSERVABILITY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --model) MODEL="$2"; shift 2 ;;
        --from-phase) FROM_PHASE="$2"; shift 2 ;;
        --skip-models) SKIP_MODELS=true; shift ;;
        --skip-verify) SKIP_VERIFY=true; shift ;;
        --with-observability) WITH_OBSERVABILITY=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: setup-maas.sh [OPTIONS]

End-to-end MaaS deployment on RHOAI 3.4. Runs all phases from operator
installation through model deployment and verification. Each phase is
idempotent  - re-running skips what's already done.

Options:
  --model <name>       Model: simulator, granite-tiny-gpu, gpt-oss-20b, auto (default: auto)
  --from-phase <N>     Start from phase N (0-7, default: 0)
  --skip-models        Skip Phase 5 (model deployment)
  --skip-verify        Skip Phase 6 (verification)
  --with-observability Also run Phase 7 (COO + Gateway telemetry)
  --dry-run            Preview without applying
  -h, --help           Show this help message

Phases:
  0  Preflight          Detect cluster state, decide which phases to run
  1  Operators          Install required operator subscriptions (RHOAI, RHCL, etc.)
  2  Platform config    Kuadrant, UWM, GatewayClass, Gateway
  3  RHOAI config       DSC with modelsAsService: Managed, Dashboard flags
  4  MaaS platform      PostgreSQL secrets/deployment, Authorino TLS
  5  Deploy model       Auto-detect GPU, apply model Kustomize manifests
  6  Verify             6-phase E2E verification (API, auth, rate limits)
  7  Observability      COO + Gateway telemetry (only with --with-observability)

Auto-detection (--model auto):
  No GPU             -> simulator (CPU-only, ~30s startup)
  GPU VRAM >= 40 GiB -> gpt-oss-20b (L40S, A100, H100)
  GPU VRAM <  40 GiB -> granite-tiny-gpu (T4, L4, A10)
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

should_run() { [ "$FROM_PHASE" -le "$1" ]; }

wait_for() {
    local desc="$1"; shift
    local timeout="${1:-120}"; shift
    log_info "Waiting for $desc (timeout: ${timeout}s)..."
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would wait for: $desc"
        return 0
    fi
    if ! "$@" --timeout="${timeout}s" 2>/dev/null; then
        log_warn "$desc did not complete within ${timeout}s"
        return 1
    fi
    log_info "$desc: done"
}

# =============================================================================
# Phase 0: Preflight
# =============================================================================
log_phase 0 "Preflight"

if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster. Run: oc login <cluster>"
    exit 1
fi
log_info "Cluster: $(oc whoami --show-server)"
log_info "User:    $(oc whoami)"

# Detect cluster domain (needed by multiple phases)
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
if [ -z "$CLUSTER_DOMAIN" ]; then
    log_error "Cannot detect cluster domain. Is this an OpenShift cluster?"
    exit 1
fi
log_info "Cluster domain: ${CLUSTER_DOMAIN}"

# Detect TLS certificate name
CERT_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator \
    -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null || echo "")
[ -z "$CERT_NAME" ] && CERT_NAME="router-certs-default"
log_info "TLS certificate: ${CERT_NAME}"

# State detection
HAS_RHOAI_CSV=false
HAS_RHCL_CSV=false
HAS_KUADRANT=false
HAS_UWM=false
HAS_GATEWAY_CLASS=false
HAS_GATEWAY=false
HAS_DSC=false
HAS_MAAS_MANAGED=false
HAS_POSTGRES=false
HAS_MAAS_API=false
HAS_TENANT=false
HAS_MODELS=false
HAS_METALLB=false

# Detect cloud vs non-cloud platform (affects Gateway LB provisioning)
PLATFORM_TYPE=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null || echo "Unknown")
IS_CLOUD_PLATFORM=false
case "$PLATFORM_TYPE" in
    AWS|GCP|Azure) IS_CLOUD_PLATFORM=true ;;
esac
log_info "Platform type: ${PLATFORM_TYPE} (cloud LB: ${IS_CLOUD_PLATFORM})"

# Note: avoid grep -q in pipelines  - with pipefail, grep -q causes SIGPIPE (exit 141)
RHOAI_CSVS=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null || true)
echo "$RHOAI_CSVS" | grep rhods >/dev/null 2>&1 && HAS_RHOAI_CSV=true
RHCL_CSVS=$(oc get csv -n openshift-operators --no-headers 2>/dev/null || true)
echo "$RHCL_CSVS" | grep rhcl >/dev/null 2>&1 && HAS_RHCL_CSV=true
oc get kuadrant kuadrant -n kuadrant-system &>/dev/null && HAS_KUADRANT=true
UWM_CFG=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)
echo "$UWM_CFG" | grep enableUserWorkload >/dev/null 2>&1 && HAS_UWM=true
oc get gatewayclass openshift-default &>/dev/null && HAS_GATEWAY_CLASS=true
oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null && HAS_GATEWAY=true
oc get datasciencecluster default-dsc &>/dev/null && HAS_DSC=true
if [ "$HAS_DSC" = true ]; then
    MAAS_STATE=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null || echo "")
    [ "$MAAS_STATE" = "Managed" ] && HAS_MAAS_MANAGED=true
fi
oc get deployment postgres -n "$NAMESPACE" &>/dev/null && HAS_POSTGRES=true
oc get deployment maas-api -n "$NAMESPACE" &>/dev/null && HAS_MAAS_API=true
oc get tenant -n models-as-a-service &>/dev/null && HAS_TENANT=true
MODEL_COUNT=$(oc get llminferenceservice -n llm --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
[ "$MODEL_COUNT" -gt 0 ] 2>/dev/null && HAS_MODELS=true
METALLB_CSVS=$(oc get csv -n metallb-system --no-headers 2>/dev/null || true)
echo "$METALLB_CSVS" | grep "metallb-operator" >/dev/null 2>&1 && HAS_METALLB=true

echo ""
log_info "Detected state:"
log_info "  RHOAI operator:     $([ "$HAS_RHOAI_CSV" = true ] && echo "installed" || echo "not found")"
log_info "  RHCL operator:      $([ "$HAS_RHCL_CSV" = true ] && echo "installed" || echo "not found")"
log_info "  Kuadrant CR:        $([ "$HAS_KUADRANT" = true ] && echo "ready" || echo "not found")"
log_info "  User Workload Mon:  $([ "$HAS_UWM" = true ] && echo "enabled" || echo "not enabled")"
log_info "  GatewayClass:       $([ "$HAS_GATEWAY_CLASS" = true ] && echo "exists" || echo "not found")"
log_info "  Gateway:            $([ "$HAS_GATEWAY" = true ] && echo "exists" || echo "not found")"
log_info "  DataScienceCluster: $([ "$HAS_DSC" = true ] && echo "exists" || echo "not found")"
log_info "  modelsAsService:    $([ "$HAS_MAAS_MANAGED" = true ] && echo "Managed" || echo "not managed")"
log_info "  PostgreSQL:         $([ "$HAS_POSTGRES" = true ] && echo "running" || echo "not deployed")"
log_info "  maas-api:           $([ "$HAS_MAAS_API" = true ] && echo "running" || echo "not deployed")"
log_info "  Tenant CR:          $([ "$HAS_TENANT" = true ] && echo "ready" || echo "not found")"
log_info "  MetalLB operator:   $([ "$HAS_METALLB" = true ] && echo "installed" || echo "not found")"
log_info "  Models deployed:    $([ "$HAS_MODELS" = true ] && echo "yes" || echo "no")"

# Determine which phases will run
PHASES_TO_RUN=""
should_run 1 && PHASES_TO_RUN="$PHASES_TO_RUN 1"
should_run 2 && PHASES_TO_RUN="$PHASES_TO_RUN 2"
should_run 3 && PHASES_TO_RUN="$PHASES_TO_RUN 3"
should_run 4 && PHASES_TO_RUN="$PHASES_TO_RUN 4"
should_run 5 && [ "$SKIP_MODELS" = false ] && PHASES_TO_RUN="$PHASES_TO_RUN 5"
should_run 6 && [ "$SKIP_VERIFY" = false ] && PHASES_TO_RUN="$PHASES_TO_RUN 6"
should_run 7 && [ "$WITH_OBSERVABILITY" = true ] && PHASES_TO_RUN="$PHASES_TO_RUN 7"
echo ""
log_info "Phases to run:${PHASES_TO_RUN:- (none)}"

# =============================================================================
# Phase 1: Operators
# =============================================================================
if should_run 1; then
    log_phase 1 "Operators"

    if [ "$HAS_RHOAI_CSV" = true ] && [ "$HAS_RHCL_CSV" = true ]; then
        log_info "Required operators already installed, skipping"
    else
        log_info "Applying operator subscriptions..."
        run_cmd oc apply -k "$GUIDE_DIR/01-prerequisites/operators/"
        log_info "Operator subscriptions applied"

        log_info "Waiting for operator CSVs (this may take 2-5 minutes)..."
        if [ "$DRY_RUN" = false ]; then
            for ns_label in \
                "redhat-ods-operator operators.coreos.com/rhods-operator.redhat-ods-operator" \
                "openshift-operators operators.coreos.com/rhcl-operator.openshift-operators" \
                "cert-manager-operator operators.coreos.com/openshift-cert-manager-operator.cert-manager-operator" \
                "openshift-operators operators.coreos.com/servicemeshoperator3.openshift-operators" \
                "openshift-lws-operator operators.coreos.com/leader-worker-set.openshift-lws-operator"
            do
                ns="${ns_label%% *}"
                label="${ns_label#* }"
                log_info "  Waiting for CSV in $ns..."
                oc wait csv -n "$ns" -l "$label=" \
                    --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s 2>/dev/null || \
                    log_warn "  CSV in $ns did not reach Succeeded within 600s"
            done
        fi
        log_info "All operator CSVs ready"
    fi
fi

# =============================================================================
# Phase 2: Platform Configuration
# =============================================================================
if should_run 2; then
    log_phase 2 "Platform Configuration"

    # Step 1: Kuadrant + Authorino TLS (per RHOAI 3.4 docs section 1.4)
    if [ "$HAS_KUADRANT" = true ]; then
        log_info "Kuadrant already configured, skipping"
    else
        log_step "Creating kuadrant-system namespace and service annotation..."
        run_cmd oc apply -f "$GUIDE_DIR/02-platform-config/kuadrant/namespace.yaml"
        run_cmd oc apply -f "$GUIDE_DIR/02-platform-config/kuadrant/service-annotation.yaml"

        log_step "Creating Kuadrant CR..."
        run_cmd oc apply -f "$GUIDE_DIR/02-platform-config/kuadrant/kuadrant.yaml"

        if [ "$DRY_RUN" = false ]; then
            if ! oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=60s 2>/dev/null; then
                KUADRANT_MSG=$(oc get kuadrant kuadrant -n kuadrant-system \
                    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
                if echo "$KUADRANT_MSG" | grep -i "MissingDependency" >/dev/null 2>&1; then
                    log_warn "Kuadrant reports MissingDependency (Istio race)  - restarting operator pod..."
                    oc delete pod -n openshift-operators -l app.kubernetes.io/name=kuadrant-operator-controller-manager 2>/dev/null || \
                        oc delete pod -n openshift-operators -l control-plane=controller-manager 2>/dev/null || \
                        oc delete pod -n openshift-operators $(oc get pods -n openshift-operators --no-headers 2>/dev/null | grep kuadrant-operator | awk '{print $1}' | head -1) 2>/dev/null || true
                    log_info "Operator pod restarted, waiting for Kuadrant Ready..."
                fi
                oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=180s 2>/dev/null || \
                    { log_error "Kuadrant did not become Ready  - check: oc get kuadrant kuadrant -n kuadrant-system -o yaml"; exit 1; }
            fi
            log_info "Kuadrant: Ready"
        else
            log_info "[DRY RUN] Would wait for Kuadrant Ready"
        fi

        log_step "Patching Authorino CR to enable TLS listener (docs section 1.4, step 2)..."
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] oc patch authorino authorino -n kuadrant-system --type=merge (enable TLS + certSecretRef)"
        else
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
            log_info "Authorino TLS listener enabled with certSecretRef: authorino-server-cert"
        fi

        log_step "Configuring Authorino TLS env vars (docs section 1.4, step 3)..."
        run_cmd oc -n kuadrant-system set env deployment/authorino \
            SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
            REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
        log_info "Authorino SSL env vars set"

        if [ "$DRY_RUN" = false ]; then
            oc get secret authorino-server-cert -n kuadrant-system &>/dev/null && \
                log_info "Authorino TLS cert generated" || \
                log_warn "Authorino TLS cert not yet available"
        fi
    fi

    # Step 2: User Workload Monitoring
    if [ "$HAS_UWM" = true ]; then
        log_info "User Workload Monitoring already enabled, skipping"
    else
        log_step "Enabling User Workload Monitoring (REQUIRED for MaaS)..."
        run_cmd oc apply -k "$GUIDE_DIR/02-platform-config/uwm/"
        log_info "UWM configured  - prometheus-user-workload pods will start shortly"
    fi

    # Step 3: GatewayClass
    if [ "$HAS_GATEWAY_CLASS" = true ]; then
        log_info "GatewayClass openshift-default already exists, skipping"
    else
        log_step "Creating GatewayClass..."
        run_cmd oc apply -f "$GUIDE_DIR/02-platform-config/gatewayclass.yaml"
        wait_for "GatewayClass accepted" 60 \
            oc wait gatewayclass openshift-default \
            --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True
    fi

    # Step 4: Gateway
    if [ "$HAS_GATEWAY" = true ]; then
        log_info "Gateway maas-default-gateway already exists, skipping"
    else
        log_step "Rendering and applying Gateway..."
        GATEWAY_TEMPLATE="$GUIDE_DIR/02-platform-config/gateway.yaml.tmpl"
        if [ ! -f "$GATEWAY_TEMPLATE" ]; then
            log_error "Gateway template not found: $GATEWAY_TEMPLATE"
            exit 1
        fi
        log_info "Rendering with CLUSTER_DOMAIN=${CLUSTER_DOMAIN}, CERT_NAME=${CERT_NAME}"
        export CLUSTER_DOMAIN CERT_NAME
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] envsubst < gateway.yaml.tmpl | oc apply -f -"
        else
            envsubst '${CLUSTER_DOMAIN} ${CERT_NAME}' < "$GATEWAY_TEMPLATE" | oc apply -f -
        fi
        if [ "$DRY_RUN" = false ]; then
            if ! oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=120s 2>/dev/null; then
                GW_REASON=$(oc get gateway maas-default-gateway -n openshift-ingress \
                    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].reason}' 2>/dev/null || echo "")
                if [ "$GW_REASON" = "AddressNotAssigned" ]; then
                    log_warn "Gateway LoadBalancer address pending (no cloud LB provisioner)"

                    # Non-cloud clusters need MetalLB to provision LB IPs
                    if [ "$IS_CLOUD_PLATFORM" = false ]; then
                        log_step "Non-cloud platform detected  - installing MetalLB..."

                        if [ "$HAS_METALLB" = false ]; then
                            log_info "Installing MetalLB operator..."
                            oc apply -k "$GUIDE_DIR/01-prerequisites/metallb/"
                            log_info "Waiting for MetalLB CSV..."
                            METALLB_TIMEOUT=120
                            METALLB_ELAPSED=0
                            while [ $METALLB_ELAPSED -lt $METALLB_TIMEOUT ]; do
                                METALLB_CSV_STATUS=$(oc get csv -n metallb-system --no-headers 2>/dev/null | grep metallb-operator | awk '{print $NF}' || echo "")
                                if [ "$METALLB_CSV_STATUS" = "Succeeded" ]; then
                                    break
                                fi
                                sleep 10
                                METALLB_ELAPSED=$((METALLB_ELAPSED + 10))
                            done
                            if [ "$METALLB_CSV_STATUS" != "Succeeded" ]; then
                                log_warn "MetalLB CSV did not reach Succeeded within ${METALLB_TIMEOUT}s (status: ${METALLB_CSV_STATUS:-unknown})"
                            else
                                log_info "MetalLB operator: Succeeded"
                            fi
                        fi

                        # Create MetalLB CR if needed
                        if ! oc get metallb metallb -n metallb-system &>/dev/null; then
                            log_info "Creating MetalLB CR..."
                            oc apply -f "$GUIDE_DIR/01-prerequisites/metallb/metallb.yaml"
                            oc wait --for=jsonpath='{.status.conditions[?(@.type=="Available")].status}'=True \
                                metallb/metallb -n metallb-system --timeout=120s 2>/dev/null || \
                                log_warn "MetalLB CR did not become Available"
                        fi

                        # Create IPAddressPool + L2Advertisement if needed
                        if ! oc get ipaddresspool maas-pool -n metallb-system &>/dev/null; then
                            NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
                            if [ -n "$NODE_IP" ]; then
                                METALLB_IP_RANGE="192.168.1.240-192.168.1.240"
                                log_info "Creating MetalLB IPAddressPool: ${METALLB_IP_RANGE}"
                                export METALLB_IP_RANGE
                                envsubst '${METALLB_IP_RANGE}' < "$GUIDE_DIR/04-maas-platform/openshift-gateway-setup/metallb-config.yaml" | oc apply -f -
                            else
                                log_warn "Cannot detect node IP for MetalLB pool"
                            fi
                        fi

                        # Wait for Gateway to pick up the MetalLB address
                        log_info "Waiting for Gateway to become Programmed with MetalLB address..."
                        if oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=60s 2>/dev/null; then
                            log_info "Gateway: Programmed (MetalLB)"
                        else
                            log_warn "Gateway still not Programmed after MetalLB setup"
                        fi
                    fi

                    # Create passthrough Route as fallback (works for both MetalLB and non-MetalLB)
                    log_info "Creating passthrough Route as fallback..."
                    ROUTE_TMPL="$GUIDE_DIR/04-maas-platform/openshift-gateway-setup/route.yaml.tmpl"
                    if [ -f "$ROUTE_TMPL" ]; then
                        export CLUSTER_DOMAIN
                        envsubst '${CLUSTER_DOMAIN}' < "$ROUTE_TMPL" | oc apply -f -
                        log_info "Route maas-default-gateway-https created  - traffic routed via OpenShift ingress"
                    else
                        log_warn "Route template not found: $ROUTE_TMPL"
                    fi
                else
                    log_warn "Gateway not Programmed (reason: ${GW_REASON:-unknown})"
                fi
            else
                log_info "Gateway: Programmed"
            fi
        else
            log_info "[DRY RUN] Would wait for Gateway Programmed"
        fi
    fi

    # Step 5: Annotate Gateway for Authorino TLS bootstrap (docs section 1.4, step 4)
    EXISTING_ANNOTATION=$(oc get gateway maas-default-gateway -n openshift-ingress \
        -o jsonpath='{.metadata.annotations.security\.opendatahub\.io/authorino-tls-bootstrap}' 2>/dev/null || echo "")
    if [ "$EXISTING_ANNOTATION" != "true" ]; then
        log_step "Annotating Gateway for Authorino TLS bootstrap (docs section 1.4, step 4)..."
        run_cmd oc annotate gateway maas-default-gateway -n openshift-ingress \
            security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite
        log_info "Gateway authorino-tls-bootstrap annotation applied"
    fi
fi

# =============================================================================
# Phase 3: RHOAI Configuration
# =============================================================================
if should_run 3; then
    log_phase 3 "RHOAI Configuration"

    if [ "$HAS_MAAS_MANAGED" = true ]; then
        log_info "DSC already has modelsAsService: Managed, skipping"
    else
        log_step "Applying DSC and DSCI..."
        run_cmd oc apply -f "$GUIDE_DIR/03-rhoai-config/dscinitialization.yaml"
        run_cmd oc apply -f "$GUIDE_DIR/03-rhoai-config/datasciencecluster.yaml"
        log_info "DSC/DSCI applied"

        if [ "$DRY_RUN" = false ]; then
            log_info "Waiting for KserveReady condition (up to 5 minutes)..."
            oc wait --for=jsonpath='{.status.conditions[?(@.type=="KserveReady")].status}'=True \
                datasciencecluster/default-dsc --timeout=300s 2>/dev/null || \
                log_warn "KserveReady did not become True within 300s"

            log_info "Waiting for ModelControllerReady condition..."
            oc wait --for=jsonpath='{.status.conditions[?(@.type=="ModelControllerReady")].status}'=True \
                datasciencecluster/default-dsc --timeout=300s 2>/dev/null || \
                log_warn "ModelControllerReady did not become True within 300s"

            if oc get crd maasmodelrefs.maas.opendatahub.io &>/dev/null; then
                log_info "MaaS CRDs registered"
            else
                log_warn "MaaS CRDs not yet registered  - operator may still be reconciling"
            fi
        fi

        log_step "Applying OdhDashboardConfig..."
        run_cmd oc apply -f "$GUIDE_DIR/03-rhoai-config/odh-dashboard-config.yaml"
        log_info "Dashboard config applied"
    fi
fi

# =============================================================================
# Phase 4: MaaS Platform
# =============================================================================
if should_run 4; then
    log_phase 4 "MaaS Platform"

    # Step 1: PostgreSQL secrets
    log_step "PostgreSQL secrets"
    if oc get secret postgres-creds -n "$NAMESPACE" &>/dev/null 2>&1; then
        log_info "postgres-creds already exists, skipping"
    else
        POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
        run_cmd oc create secret generic postgres-creds \
            -n "$NAMESPACE" \
            --from-literal=POSTGRES_USER=maas \
            --from-literal=POSTGRES_DB=maas \
            --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
        run_cmd oc create secret generic maas-db-config \
            -n "$NAMESPACE" \
            --from-literal=DB_CONNECTION_URL="postgresql://maas:${POSTGRES_PASSWORD}@postgres.${NAMESPACE}.svc:5432/maas?sslmode=disable"
        log_info "PostgreSQL secrets created"
    fi

    # Step 2: PostgreSQL deployment
    log_step "PostgreSQL deployment"
    if [ "$HAS_POSTGRES" = true ]; then
        log_info "PostgreSQL already deployed, skipping"
    else
        run_cmd oc apply -k "$GUIDE_DIR/04-maas-platform/"
        wait_for "PostgreSQL available" 120 \
            oc wait --for=condition=Available deployment/postgres -n "$NAMESPACE"
    fi

    # Step 3: Ensure Gateway + TLS exists (may have been created in Phase 2)
    if ! oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null 2>&1; then
        log_step "Rendering and applying Gateway (not created in Phase 2)..."
        export CLUSTER_DOMAIN CERT_NAME
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] envsubst < gateway.yaml.tmpl | oc apply -f -"
        else
            envsubst '${CLUSTER_DOMAIN} ${CERT_NAME}' < "$GUIDE_DIR/02-platform-config/gateway.yaml.tmpl" | oc apply -f -
        fi
    fi
    # Ensure Authorino TLS is configured (may have been done in Phase 2)
    AUTHORINO_TLS=$(oc get authorino authorino -n kuadrant-system \
        -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || echo "")
    if [ "$AUTHORINO_TLS" != "true" ]; then
        log_step "Patching Authorino CR for TLS (docs section 1.4, step 2)..."
        run_cmd oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
          "spec": {"listener": {"tls": {"enabled": true, "certSecretRef": {"name": "authorino-server-cert"}}}}
        }'
    fi
    EXISTING_ENVS=$(oc get deployment authorino -n kuadrant-system \
        -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null || echo "")
    if ! echo "$EXISTING_ENVS" | grep SSL_CERT_FILE >/dev/null 2>&1; then
        log_step "Configuring Authorino TLS env vars (docs section 1.4, step 3)..."
        run_cmd oc -n kuadrant-system set env deployment/authorino \
            SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
            REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
    fi
    EXISTING_ANNOTATION=$(oc get gateway maas-default-gateway -n openshift-ingress \
        -o jsonpath='{.metadata.annotations.security\.opendatahub\.io/authorino-tls-bootstrap}' 2>/dev/null || echo "")
    if [ "$EXISTING_ANNOTATION" != "true" ]; then
        log_step "Annotating Gateway for TLS bootstrap (docs section 1.4, step 4)..."
        run_cmd oc annotate gateway maas-default-gateway -n openshift-ingress \
            security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite
    fi

    # Step 4: Wait for maas-api
    log_step "Waiting for maas-api deployment"
    if [ "$HAS_MAAS_API" = true ]; then
        log_info "maas-api already running"
    elif [ "$DRY_RUN" = false ]; then
        TIMEOUT=300
        ELAPSED=0
        while [ $ELAPSED -lt $TIMEOUT ]; do
            if oc get deployment maas-api -n "$NAMESPACE" &>/dev/null; then
                log_info "maas-api deployment found"
                oc rollout status deployment/maas-api -n "$NAMESPACE" --timeout=180s 2>/dev/null || \
                    log_warn "maas-api rollout did not complete within 180s"
                break
            fi
            sleep 10
            ELAPSED=$((ELAPSED + 10))
            if [ $((ELAPSED % 60)) -eq 0 ]; then
                log_info "Still waiting for maas-api... (${ELAPSED}s)"
            fi
        done
        [ $ELAPSED -ge $TIMEOUT ] && log_warn "maas-api not found after ${TIMEOUT}s  - operator may still be reconciling"
    fi

    # Step 5: Verify Tenant CR
    if [ "$DRY_RUN" = false ]; then
        TENANT_READY=$(oc get tenant default-tenant -n models-as-a-service \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$TENANT_READY" = "True" ]; then
            log_info "Tenant CR: Ready"
        else
            log_warn "Tenant CR not Ready yet (status: ${TENANT_READY:-not found})"
        fi
    fi

    # Health check
    if [ "$DRY_RUN" = false ]; then
        HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
            "https://maas.${CLUSTER_DOMAIN}/maas-api/health" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ]; then
            log_info "Health endpoint: HTTP 200"
        elif [ "$HTTP_CODE" = "401" ]; then
            log_info "Health endpoint: HTTP 401 (auth working, health may need token)"
        else
            log_warn "Health endpoint: HTTP ${HTTP_CODE} (may need DNS propagation)"
        fi
    fi
fi

# =============================================================================
# Phase 5: Deploy Model
# =============================================================================
if should_run 5 && [ "$SKIP_MODELS" = false ]; then
    log_phase 5 "Deploy Model"

    if [ "$HAS_MODELS" = true ]; then
        log_info "Models already deployed in llm namespace:"
        oc get llminferenceservice -n llm --no-headers 2>/dev/null || true
        log_info "Skipping model deployment (use --from-phase 5 to force)"
    else
        # Auto-detect model
        if [ "$MODEL" = "auto" ]; then
            log_step "Auto-detecting GPU capabilities..."
            GPU_MEMORY=$(oc get nodes -o jsonpath='{.items[*].metadata.labels.nvidia\.com/gpu\.memory}' 2>/dev/null \
                | tr ' ' '\n' | sort -rn | head -1)
            if [ -z "$GPU_MEMORY" ]; then
                MODEL="simulator"
                log_info "No GPU nodes detected -> simulator"
            elif [ "$GPU_MEMORY" -ge 40960 ] 2>/dev/null; then
                MODEL="gpt-oss-20b"
                log_info "GPU VRAM: ${GPU_MEMORY} MiB (>= 40960) -> gpt-oss-20b"
            else
                MODEL="granite-tiny-gpu"
                log_info "GPU VRAM: ${GPU_MEMORY} MiB (< 40960) -> granite-tiny-gpu"
            fi
        fi

        VALID_MODELS="simulator granite-tiny-gpu gpt-oss-20b"
        if ! echo "$VALID_MODELS" | grep -qw "$MODEL"; then
            log_error "Unknown model: $MODEL (valid: $VALID_MODELS)"
            exit 1
        fi

        MODEL_DIR="$GUIDE_DIR/05-maas-models/$MODEL"
        if [ ! -d "$MODEL_DIR" ]; then
            log_error "Model directory not found: $MODEL_DIR"
            exit 1
        fi

        log_step "Deploying model: $MODEL"
        if ! oc get namespace llm &>/dev/null; then
            run_cmd oc create namespace llm
        fi
        run_cmd oc apply -k "$MODEL_DIR/"
        log_info "Model manifests applied"

        if [ "$DRY_RUN" = false ]; then
            # Wait for pods
            log_info "Waiting for model pods (up to 10 minutes for GPU models)..."
            TIMEOUT=600
            ELAPSED=0
            while [ $ELAPSED -lt $TIMEOUT ]; do
                POD_COUNT=$(oc get pods -n llm --no-headers 2>/dev/null | wc -l | tr -d ' ')
                if [ "$POD_COUNT" -gt 0 ]; then
                    NOT_READY=$(oc get pods -n llm --no-headers 2>/dev/null \
                        | grep -v "Running\|Completed" | wc -l | tr -d ' ')
                    if [ "$NOT_READY" -eq 0 ]; then
                        log_info "All model pods Running"
                        break
                    fi
                fi
                sleep 10
                ELAPSED=$((ELAPSED + 10))
                [ $((ELAPSED % 60)) -eq 0 ] && log_info "  Still waiting... (${ELAPSED}s)"
            done
            [ $ELAPSED -ge $TIMEOUT ] && log_warn "Pods not all Running after ${TIMEOUT}s"

            # Wait for MaaSModelRef
            log_info "Waiting for MaaSModelRef phase=Ready..."
            TIMEOUT=300
            ELAPSED=0
            while [ $ELAPSED -lt $TIMEOUT ]; do
                PHASE=$(oc get maasmodelref -n llm -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
                [ "$PHASE" = "Ready" ] && break
                sleep 10
                ELAPSED=$((ELAPSED + 10))
            done
            if [ "${PHASE:-}" = "Ready" ]; then
                log_info "MaaSModelRef: Ready"
            else
                log_warn "MaaSModelRef not Ready after ${TIMEOUT}s (phase: ${PHASE:-unknown})"
            fi
        fi
    fi
fi

# =============================================================================
# Phase 6: Verify
# =============================================================================
if should_run 6 && [ "$SKIP_VERIFY" = false ]; then
    log_phase 6 "Verify"

    VERIFY_SCRIPT="$GUIDE_DIR/06-verification/verify.sh"
    if [ ! -x "$VERIFY_SCRIPT" ]; then
        log_error "Verification script not found or not executable: $VERIFY_SCRIPT"
    elif [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would run: $VERIFY_SCRIPT"
    else
        log_info "Running E2E verification..."
        "$VERIFY_SCRIPT" || log_warn "Verification had failures  - check output above"
    fi
fi

# =============================================================================
# Phase 7: Observability (Optional)
# =============================================================================
if should_run 7 && [ "$WITH_OBSERVABILITY" = true ]; then
    log_phase 7 "Observability"

    # COO
    log_step "Installing Cluster Observability Operator..."
    run_cmd oc apply -k "$GUIDE_DIR/07-observability/coo/"
    if [ "$DRY_RUN" = false ]; then
        log_info "Waiting for COO CSV..."
        TIMEOUT=300
        ELAPSED=0
        while [ $ELAPSED -lt $TIMEOUT ]; do
            COO_PHASE=$(oc get csv -n openshift-cluster-observability-operator --no-headers 2>/dev/null \
                | grep cluster-observability | awk '{print $NF}' || echo "")
            [ "$COO_PHASE" = "Succeeded" ] && break
            sleep 10
            ELAPSED=$((ELAPSED + 10))
        done
        if [ "${COO_PHASE:-}" = "Succeeded" ]; then
            log_info "COO CSV: Succeeded"
        else
            log_warn "COO CSV not Succeeded after ${TIMEOUT}s"
        fi
    fi

    # Telemetry
    log_step "Applying Gateway telemetry..."
    run_cmd oc apply -k "$GUIDE_DIR/07-observability/telemetry/"
    log_info "Gateway telemetry applied"
fi

# =============================================================================
# Final Summary
# =============================================================================
echo ""
log_phase "" "Summary"

MAAS_URL="https://maas.${CLUSTER_DOMAIN}"

if [ "$DRY_RUN" = true ]; then
    log_info "MaaS API URL:  ${MAAS_URL}"
    log_info "Status:        DRY RUN  - no changes applied"
else
    # Gather final state
    RHOAI_VERSION=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods | awk '{print $2}' || echo "unknown")
    GW_STATUS=$(oc get gateway maas-default-gateway -n openshift-ingress \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")
    API_READY=$(oc get deployment maas-api -n "$NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    HEALTH=$(curl -sk -o /dev/null -w '%{http_code}' "${MAAS_URL}/maas-api/health" 2>/dev/null || echo "000")

    log_info "RHOAI version: ${RHOAI_VERSION}"
    log_info "MaaS API URL:  ${MAAS_URL}"
    log_info "Gateway:       Programmed=${GW_STATUS}"
    log_info "maas-api:      ${API_READY} replica(s)"
    log_info "Health:        HTTP ${HEALTH}"

    if [ "$SKIP_MODELS" = false ] && [ "$HAS_MODELS" = true ] || oc get llminferenceservice -n llm &>/dev/null 2>&1; then
        log_info "Models:"
        oc get llminferenceservice -n llm --no-headers 2>/dev/null | while read -r line; do
            log_info "  $line"
        done
    fi

    echo ""
    log_info "Next steps:"
    [ "$SKIP_MODELS" = true ] && log_info "  Deploy models:      ./scripts/deploy-model.sh --model auto"
    [ "$SKIP_VERIFY" = true ] && log_info "  Run verification:   ./scripts/verify-maas.sh"
    [ "$WITH_OBSERVABILITY" = false ] && log_info "  Add observability:  $0 --from-phase 7 --with-observability"
    log_info "  RHOAI Dashboard:    https://$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo '<dashboard-route>')"
fi

echo ""
log_info "Done."
