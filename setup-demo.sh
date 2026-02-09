#!/bin/bash

# Cisco Boutique Demo Setup Script
# This script automates the complete setup of the Cisco Boutique demo environment
# including Kind cluster, Cilium CNI with L2 announcements + BGP, Gateway API,
# Hubble, FRR router for BGP peering, and the boutique application.
#
# The demo is fully repeatable - just run it again and it will tear down and rebuild.

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
CLUSTER_NAME="kind"
CILIUM_VERSION="1.18.4"
GATEWAY_API_VERSION="v1.2.0"
FRR_IMAGE="frrouting/frr:v8.2.2"
FRR_CONTAINER_NAME="frr"
CILIUM_LOCAL_ASN=64513
FRR_ASN=64512

# Logging functions
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ─── Prerequisites ───────────────────────────────────────────────────────────

check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing_tools=()
    for tool in docker kind kubectl helm cilium mkcert; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Install guides:"
        log_info "  docker:     https://docs.docker.com/get-docker/"
        log_info "  kind:       https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
        log_info "  kubectl:    https://kubernetes.io/docs/tasks/tools/"
        log_info "  helm:       https://helm.sh/docs/intro/install/"
        log_info "  cilium CLI: https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli"
        log_info "  mkcert:     brew install mkcert"
        exit 1
    fi

    if ! docker info &>/dev/null; then
        log_error "Docker is not running. Please start Docker and try again."
        exit 1
    fi

    log_success "All prerequisites met"
}

# ─── Cluster ─────────────────────────────────────────────────────────────────

cleanup_existing() {
    # Remove any leftover FRR container
    if docker ps -a --format '{{.Names}}' | grep -q "^${FRR_CONTAINER_NAME}$"; then
        log_warning "Removing existing FRR container..."
        docker rm -f "$FRR_CONTAINER_NAME" &>/dev/null || true
    fi

    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_warning "Existing Kind cluster '${CLUSTER_NAME}' found. Deleting..."
        kind delete cluster --name "$CLUSTER_NAME"
        log_success "Existing cluster deleted"
    fi
}

create_cluster() {
    log_info "🏗️  Creating Kind cluster..."

    if [ ! -f "$SCRIPT_DIR/kind.yaml" ]; then
        log_error "kind.yaml not found in $SCRIPT_DIR"
        exit 1
    fi

    kind create cluster --config="$SCRIPT_DIR/kind.yaml" --name "$CLUSTER_NAME"
    sleep 5
    kubectl cluster-info --context "kind-${CLUSTER_NAME}"
    log_success "Kind cluster created"
}

# ─── Image Pre-loading ───────────────────────────────────────────────────────

preload_images() {
    log_info "📥 Pre-loading Cilium images into Kind nodes..."

    # Ensure Helm repo is available for image extraction
    helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
    helm repo update cilium

    # Fetch the image list from the Cilium Helm chart.
    # We extract full image refs (may include @sha256: digests), then strip digests
    # for docker pull and kind load. kind load mangles digest-tagged images, causing
    # containerd to not find them (the "import-YYYY-MM-DD" bug).
    local raw_images
    raw_images=$(helm template cilium cilium/cilium \
        --version "$CILIUM_VERSION" \
        --values "$SCRIPT_DIR/cilium-gatewayapi-values.yaml" \
        2>/dev/null | grep 'image:' | sed 's/.*image: *//; s/"//g; s/ *$//' | sort -u)

    if [ -z "$raw_images" ]; then
        log_warning "Could not extract images from Helm chart, skipping pre-load"
        return 0
    fi

    # Strip @sha256:... digests — use tag-only references for pull and load.
    # e.g. quay.io/cilium/cilium:v1.18.4@sha256:abc123 → quay.io/cilium/cilium:v1.18.4
    local images
    images=$(echo "$raw_images" | sed 's/@sha256:[a-f0-9]*//' | sort -u)

    local total
    total=$(echo "$images" | wc -l | tr -d ' ')
    local count=0
    local failed=0

    while IFS= read -r image; do
        count=$((count + 1))
        log_info "  [$count/$total] Pulling: ${image}"
        if docker pull "$image" 2>/dev/null; then
            log_success "  [$count/$total] Pulled: ${image}"
        else
            log_warning "  [$count/$total] Failed to pull: ${image} (will retry at install time)"
            failed=$((failed + 1))
        fi
    done <<< "$images"

    if [ "$failed" -eq "$total" ]; then
        log_warning "All image pulls failed — check network connectivity. Cilium install will pull images directly."
        return 0
    fi

    log_info "  Loading images into Kind cluster (this may take a minute)..."
    while IFS= read -r image; do
        kind load docker-image "$image" --name "$CLUSTER_NAME" 2>/dev/null || true
    done <<< "$images"

    log_success "Images pre-loaded into Kind nodes ($((total - failed))/$total successful)"
}

# ─── Gateway API CRDs ────────────────────────────────────────────────────────

install_gateway_api_crds() {
    log_info "📦 Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."

    local crd_base="https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/standard"

    kubectl apply -f "${crd_base}/gateway.networking.k8s.io_gatewayclasses.yaml"
    kubectl apply -f "${crd_base}/gateway.networking.k8s.io_gateways.yaml"
    kubectl apply -f "${crd_base}/gateway.networking.k8s.io_httproutes.yaml"
    kubectl apply -f "${crd_base}/gateway.networking.k8s.io_referencegrants.yaml"
    kubectl apply -f "${crd_base}/gateway.networking.k8s.io_grpcroutes.yaml"

    log_success "Gateway API CRDs installed"
}

# ─── Cilium ──────────────────────────────────────────────────────────────────

install_cilium() {
    log_info "🐝 Installing Cilium with Gateway API + BGP + L2 Announcements + Hubble..."

    helm install cilium cilium/cilium \
        --version "$CILIUM_VERSION" \
        -n kube-system \
        --values "$SCRIPT_DIR/cilium-gatewayapi-values.yaml"

    log_info "⏳ Waiting for Cilium to be ready (timeout: 5 minutes)..."
    if ! cilium status --wait --wait-duration 5m; then
        log_error "Cilium did not become ready within 5 minutes"
        log_info "Current status:"
        cilium status || true
        log_info "Pod status:"
        kubectl get pods -n kube-system -l k8s-app=cilium -o wide || true
        kubectl get pods -n kube-system -l k8s-app=cilium-envoy -o wide || true
        exit 1
    fi
    log_success "Cilium installed"
}

# ─── L2 Announcements ───────────────────────────────────────────────────────

configure_l2_announcements() {
    log_info "📡 Configuring L2 announcement policy..."
    kubectl apply -f "$SCRIPT_DIR/l2-announcement-policy.yaml"
    log_success "L2 announcement policy applied"
}

# ─── LoadBalancer IP Pool ────────────────────────────────────────────────────

configure_loadbalancer_pool() {
    log_info "🌐 Configuring LoadBalancer IP pool..."
    kubectl apply -f "$SCRIPT_DIR/loadbalancer-ip-pool.yaml"
    log_success "LoadBalancer IP pool configured"
}

# ─── FRR Router ──────────────────────────────────────────────────────────────

deploy_frr_router() {
    # NOTE: This function returns the FRR IP via stdout (echo at the end).
    # All log messages MUST go to stderr (&2) so they don't pollute the return value.
    log_info "🔄 Deploying FRR router for BGP peering..." >&2

    # Get the Kind worker node IPs (these are the Cilium BGP speakers)
    local WORKER1_IP WORKER2_IP
    WORKER1_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' kind-worker)"
    WORKER2_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' kind-worker2)"
    log_info "  kind-worker  IP: ${WORKER1_IP}" >&2
    log_info "  kind-worker2 IP: ${WORKER2_IP}" >&2

    # Start FRR container on the Kind Docker network
    # Use /usr/lib/frr/docker-start as the entrypoint so FRR runs indefinitely
    docker rm -f "$FRR_CONTAINER_NAME" &>/dev/null || true
    docker run -d --name "$FRR_CONTAINER_NAME" \
        --network kind \
        --privileged \
        "$FRR_IMAGE" /bin/bash -c "tail -f /dev/null" >/dev/null

    # Get the FRR container IP (assigned by Docker on the kind network)
    local FRR_IP
    FRR_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$FRR_CONTAINER_NAME")"
    log_info "  FRR router   IP: ${FRR_IP}" >&2

    # Generate the FRR configuration with the actual IPs
    cat > "$SCRIPT_DIR/frr/frr.conf" <<EOF
log syslog informational
router id ${FRR_IP}

router bgp ${FRR_ASN}
 bgp router-id ${FRR_IP}
 neighbor ${WORKER1_IP} remote-as ${CILIUM_LOCAL_ASN}
 neighbor ${WORKER1_IP} update-source eth0

 neighbor ${WORKER2_IP} remote-as ${CILIUM_LOCAL_ASN}
 neighbor ${WORKER2_IP} update-source eth0

 address-family ipv4 unicast
  neighbor ${WORKER1_IP} activate
  neighbor ${WORKER1_IP} soft-reconfiguration inbound
  neighbor ${WORKER1_IP} route-map ACCEPT-IN in
  neighbor ${WORKER1_IP} route-map DENY-OUT out

  neighbor ${WORKER2_IP} activate
  neighbor ${WORKER2_IP} soft-reconfiguration inbound
  neighbor ${WORKER2_IP} route-map ACCEPT-IN in
  neighbor ${WORKER2_IP} route-map DENY-OUT out
 exit-address-family

route-map ACCEPT-IN permit 10
route-map DENY-OUT deny 10
EOF

    # Copy config files into the FRR container and restart the daemon
    docker cp "$SCRIPT_DIR/frr/frr.conf"   "${FRR_CONTAINER_NAME}:/etc/frr/frr.conf" >/dev/null 2>&1
    docker cp "$SCRIPT_DIR/frr/daemons"     "${FRR_CONTAINER_NAME}:/etc/frr/daemons" >/dev/null 2>&1
    docker cp "$SCRIPT_DIR/frr/vtysh.conf"  "${FRR_CONTAINER_NAME}:/etc/frr/vtysh.conf" >/dev/null 2>&1
    docker exec "$FRR_CONTAINER_NAME" /usr/lib/frr/frrinit.sh restart >/dev/null 2>&1

    # Wait for BGP daemon to be ready
    sleep 3
    if docker exec "$FRR_CONTAINER_NAME" vtysh -c "show bgp summary" &>/dev/null; then
        log_success "FRR router deployed (AS ${FRR_ASN}, IP ${FRR_IP})" >&2
    else
        log_warning "FRR started but BGP daemon may still be initializing" >&2
    fi

    # Return the FRR IP for the BGP cluster config (only this goes to stdout)
    echo "$FRR_IP"
}

# ─── Cilium BGP Peering ─────────────────────────────────────────────────────

configure_bgp_peering() {
    local FRR_IP="$1"
    log_info "🔗 Configuring Cilium BGP peering with FRR (${FRR_IP})..."

    # Apply the peer config and advertisement (static files)
    kubectl apply -f "$SCRIPT_DIR/bgp-peer.yaml"
    kubectl apply -f "$SCRIPT_DIR/bgp-advertisement.yaml"

    # Generate and apply the CiliumBGPClusterConfig with the FRR router IP
    cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata:
  name: frr
spec:
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
  bgpInstances:
  - name: "${CILIUM_LOCAL_ASN}"
    localASN: ${CILIUM_LOCAL_ASN}
    peers:
    - name: "frr"
      peerASN: ${FRR_ASN}
      peerAddress: ${FRR_IP}
      peerConfigRef:
        name: "frr"
EOF

    log_success "BGP peering configured (Cilium AS ${CILIUM_LOCAL_ASN} <-> FRR AS ${FRR_ASN})"
}

# ─── Cisco Boutique ─────────────────────────────────────────────────────────

deploy_boutique() {
    log_info "🛒 Deploying Cisco Boutique application..."

    kubectl apply -f "$SCRIPT_DIR/boutique-manifests.yaml"

    log_info "⏳ Waiting for boutique pods to be ready (timeout: 10 minutes)..."
    # Wait for deployments to exist first (kubectl apply is synchronous but pods take time)
    sleep 10
    if ! kubectl wait --for=condition=Available deployments --all -n ciscoboutique --timeout=600s; then
        log_error "Some boutique deployments did not become available"
        kubectl get pods -n ciscoboutique -o wide
        exit 1
    fi
    kubectl wait --for=condition=Ready pods --all -n ciscoboutique --timeout=120s
    log_success "Cisco Boutique deployed"
}

# ─── Gateway API Resources ───────────────────────────────────────────────────

deploy_gateway_api() {
    log_info "🌐 Deploying Gateway API routes..."

    # Generate TLS certificate if needed
    if [ ! -f "$SCRIPT_DIR/_wildcard.cilium.rocks.pem" ] || [ ! -f "$SCRIPT_DIR/_wildcard.cilium.rocks-key.pem" ]; then
        log_info "Generating wildcard certificate for *.cilium.rocks..."
        (cd "$SCRIPT_DIR" && mkcert '*.cilium.rocks')
    else
        log_info "TLS certificate already exists, skipping generation"
    fi

    # Create Kubernetes TLS secret
    kubectl create secret tls demo-cert \
        --key="$SCRIPT_DIR/_wildcard.cilium.rocks-key.pem" \
        --cert="$SCRIPT_DIR/_wildcard.cilium.rocks.pem" \
        -n ciscoboutique \
        --dry-run=client -o yaml | kubectl apply -f -

    # Apply Gateway and HTTPRoutes
    kubectl apply -f "$SCRIPT_DIR/gateway-api-example.yaml"

    log_info "⏳ Waiting for Gateway to be programmed..."
    kubectl wait --for=condition=Programmed gateway/cisco-boutique-gateway -n ciscoboutique --timeout=120s

    log_success "Gateway API deployed"
}

# ─── Verification ────────────────────────────────────────────────────────────

verify_deployment() {
    log_info "🔍 Verifying deployment..."
    echo

    log_info "Cluster nodes:"
    kubectl get nodes -o wide
    echo

    log_info "Cilium status:"
    cilium status
    echo

    log_info "Cisco Boutique pods:"
    kubectl get pods -n ciscoboutique -o wide
    echo

    log_info "Services:"
    kubectl get svc -n ciscoboutique
    echo

    log_info "Gateway:"
    kubectl get gateway -n ciscoboutique
    echo

    log_info "HTTPRoutes:"
    kubectl get httproute -n ciscoboutique
    echo

    log_success "Deployment verification complete"
}

verify_bgp() {
    local FRR_IP="$1"
    log_info "🔗 Verifying BGP peering..."
    echo

    log_info "Cilium BGP peers:"
    cilium bgp peers
    echo

    log_info "Cilium BGP advertised routes to FRR (${FRR_IP}):"
    cilium bgp routes advertised ipv4 unicast peer "${FRR_IP}" || log_warning "No advertised routes yet (BGP session may still be converging)"
    echo

    log_info "FRR received routes:"
    docker exec "$FRR_CONTAINER_NAME" vtysh -c "show bgp ipv4 unicast" 2>/dev/null || log_warning "FRR BGP table not yet populated (may take a few seconds)"
    echo

    log_success "BGP verification complete"
}

# ─── Summary ─────────────────────────────────────────────────────────────────

show_summary() {
    local GATEWAY_IP
    GATEWAY_IP=$(kubectl get gateway cisco-boutique-gateway -n ciscoboutique \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "<pending>")

    echo
    echo "============================================================"
    log_success "🎉 Cisco Boutique Demo is ready!"
    echo "============================================================"
    echo
    log_info "Gateway IP: ${GATEWAY_IP}"
    echo
    log_info "Quick test commands:"
    echo "  curl -H 'Host: boutique.cilium.rocks' http://${GATEWAY_IP}/"
    echo "  curl -I  http://${GATEWAY_IP}/redirect-to-cisco-store"
    echo
    log_info "L2 announcements (local access):"
    echo "  kubectl get ciliuml2announcementpolicy"
    echo "  kubectl get leases -n kube-system -l cilium.io/l2-announcement"
    echo
    log_info "BGP commands:"
    echo "  cilium bgp peers"
    echo "  docker exec frr vtysh -c 'show bgp ipv4 unicast'"
    echo "  docker exec frr vtysh -c 'show bgp summary'"
    echo
    log_info "Hubble:"
    echo "  cilium hubble ui"
    echo "  cilium hubble port-forward"
    echo
    log_info "Gateway API demo:"
    echo "  ./gateway-api-demo.sh status"
    echo "  ./gateway-api-demo.sh test"
    echo "  ./gateway-api-demo.sh canary"
    echo
    log_info "Cleanup:"
    echo "  ./cleanup-demo.sh"
    echo
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    echo
    log_info "🚀 Starting Cisco Boutique Demo Setup"
    echo "======================================="
    echo

    check_prerequisites
    cleanup_existing
    create_cluster
    preload_images
    install_gateway_api_crds
    install_cilium

    # Network plumbing: L2 for local access, BGP for external advertisement
    configure_l2_announcements
    configure_loadbalancer_pool

    deploy_boutique

    # Deploy FRR and configure BGP peering
    FRR_IP=$(deploy_frr_router)
    configure_bgp_peering "$FRR_IP"

    # Deploy Gateway API (gets LB IP announced via L2 + advertised via BGP to FRR)
    deploy_gateway_api

    # Verify everything
    verify_deployment
    verify_bgp "$FRR_IP"
    show_summary

    log_success "Setup complete!"
}

main "$@"