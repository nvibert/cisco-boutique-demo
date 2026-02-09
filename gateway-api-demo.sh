#!/bin/bash

# Gateway API Demo Script for Cisco Boutique
# This script demonstrates Gateway API capabilities as an Ingress replacement

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if mkcert is installed
    if ! command -v mkcert >/dev/null 2>&1; then
        log_error "mkcert is required but not installed."
        log_info "Please install mkcert first:"
        log_info "  macOS: brew install mkcert"
        log_info "  Linux: See https://github.com/FiloSottile/mkcert#installation"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Function to generate TLS certificate using mkcert
generate_certificate() {
    log_info "Generating wildcard certificate for *.cilium.rocks..."
    
    # Generate certificate if it doesn't exist
    if [ ! -f "_wildcard.cilium.rocks.pem" ] || [ ! -f "_wildcard.cilium.rocks-key.pem" ]; then
        mkcert '*.cilium.rocks'
        log_success "Certificate generated successfully"
    else
        log_info "Certificate files already exist, skipping generation"
    fi
    
    # Create Kubernetes TLS secret
    log_info "Creating TLS secret in Kubernetes..."
    kubectl create secret tls demo-cert \
        --key=_wildcard.cilium.rocks-key.pem \
        --cert=_wildcard.cilium.rocks.pem \
        -n ciscoboutique \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "TLS secret created/updated"
}

# Function to deploy Gateway API resources
deploy_gateway_api() {
    log_info "Deploying Gateway API resources..."
    
    # Check if the YAML file exists
    if [ ! -f "$SCRIPT_DIR/gateway-api-example.yaml" ]; then
        log_error "gateway-api-example.yaml not found in $SCRIPT_DIR"
        exit 1
    fi
    
    # Apply the Gateway API configuration
    kubectl apply -f "$SCRIPT_DIR/gateway-api-example.yaml"
    
    # Wait for Gateway to be ready
    log_info "Waiting for Gateway to be ready..."
    kubectl wait --for=condition=Programmed gateway/cisco-boutique-gateway -n ciscoboutique --timeout=120s
    
    log_success "Gateway API resources deployed successfully"
}

# Function to check if Gateway API CRDs are installed
check_gateway_api() {
    log_info "Checking Gateway API CRDs..."
    
    local required_crds=("gatewayclasses.gateway.networking.k8s.io" "gateways.gateway.networking.k8s.io" "httproutes.gateway.networking.k8s.io")
    local missing_crds=()
    
    for crd in "${required_crds[@]}"; do
        if ! kubectl get crd "$crd" >/dev/null 2>&1; then
            missing_crds+=("$crd")
        fi
    done
    
    if [ ${#missing_crds[@]} -ne 0 ]; then
        log_error "Missing Gateway API CRDs: ${missing_crds[*]}"
        log_info "Please run the setup-demo.sh script first to install Gateway API CRDs"
        exit 1
    fi
    
    log_success "Gateway API CRDs are installed"
}

# Function to show Gateway status
show_gateway_status() {
    log_info "Gateway API Status:"
    echo
    
    # Show GatewayClass
    log_info "GatewayClass:"
    kubectl get gatewayclass cilium -o wide
    echo
    
    # Show Gateway
    log_info "Gateway:"
    kubectl get gateway -n ciscoboutique cisco-boutique-gateway -o wide
    echo
    
    # Show HTTPRoutes
    log_info "HTTPRoutes:"
    kubectl get httproute -n ciscoboutique
    echo
    
    # Show Gateway details
    log_info "Gateway Details:"
    kubectl describe gateway cisco-boutique-gateway -n ciscoboutique
}

# Function to get Gateway IP
get_gateway_ip() {
    log_info "Getting Gateway IP address..."
    
    local gateway_ip
    gateway_ip=$(kubectl get gateway cisco-boutique-gateway -n ciscoboutique -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
    
    if [ -n "$gateway_ip" ]; then
        log_success "Gateway IP: $gateway_ip"
        return 0
    else
        log_warning "Gateway IP not yet assigned. Checking service..."
        kubectl get svc -n ciscoboutique -l "gateway.networking.k8s.io/gateway-name=cisco-boutique-gateway"
        return 1
    fi
}

# Function to configure local DNS
configure_local_dns() {
    log_info "Configuring local DNS entries..."
    
    local gateway_ip
    gateway_ip=$(kubectl get gateway cisco-boutique-gateway -n ciscoboutique -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
    
    if [ -z "$gateway_ip" ]; then
        log_error "Gateway IP not available. Cannot configure DNS."
        return 1
    fi
    
    # List of hostnames to configure
    local hostnames=("boutique.cilium.rocks" "www.boutique.cilium.rocks" "api.boutique.cilium.rocks" "admin.boutique.cilium.rocks" "health.boutique.cilium.rocks")
    
    log_warning "To access the Gateway API routes, add these entries to your /etc/hosts file:"
    echo
    for hostname in "${hostnames[@]}"; do
        echo "$gateway_ip $hostname"
    done
    echo
    
    log_info "You can add them automatically with:"
    echo "sudo bash -c 'cat << EOF >> /etc/hosts"
    for hostname in "${hostnames[@]}"; do
        echo "$gateway_ip $hostname"
    done
    echo "EOF'"
    echo
}

# Function to test Gateway API routes with proper CA
test_routes() {
    log_info "Testing Gateway API routes..."
    
    local gateway_ip
    gateway_ip=$(kubectl get gateway cisco-boutique-gateway -n ciscoboutique -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
    
    if [ -z "$gateway_ip" ]; then
        log_error "Gateway IP not available. Cannot test routes."
        return 1
    fi
    
    # Get mkcert CA root path
    local ca_root
    ca_root=$(mkcert -CAROOT 2>/dev/null || echo "")
    
    log_info "Testing routes with mkcert CA validation:"
    echo
    
    if [ -n "$ca_root" ] && [ -f "$ca_root/rootCA.pem" ]; then
        log_info "Using mkcert CA for HTTPS validation:"
        echo "export GATEWAY_IP=$gateway_ip"
        echo "export CA_ROOT=\"$ca_root\""
        echo
        
        # Test HTTPS routes with proper CA
        log_info "Testing HTTPS frontend route:"
        echo "curl -s --resolve \"boutique.cilium.rocks:443:\$GATEWAY_IP\" \\"
        echo "     --cacert \"\$CA_ROOT/rootCA.pem\" \\"
        echo "     https://boutique.cilium.rocks/"
        echo
        
        log_info "Testing HTTPS API routes:"
        echo "curl -s --resolve \"api.boutique.cilium.rocks:443:\$GATEWAY_IP\" \\"
        echo "     --cacert \"\$CA_ROOT/rootCA.pem\" \\"
        echo "     https://api.boutique.cilium.rocks/api/products"
        echo
    else
        log_warning "mkcert CA not found, showing HTTP examples:"
    fi
    
    # Test HTTP routes (fallback)
    log_info "Testing HTTP routes:"
    echo "curl -H 'Host: boutique.cilium.rocks' http://$gateway_ip/"
    echo "curl -H 'Host: api.boutique.cilium.rocks' http://$gateway_ip/api/products"
    echo "curl -H 'Host: admin.boutique.cilium.rocks' http://$gateway_ip/admin"
    echo "curl -H 'Host: health.boutique.cilium.rocks' http://$gateway_ip/health/frontend"
    echo
    
    # Test redirect (the cheeky example!)
    log_info "Testing legal compliance redirect (the cheeky example!):"
    echo "# Test redirect (should return 301):"
    echo "curl -H 'Host: boutique.cilium.rocks' -I http://$gateway_ip/redirect-to-cisco-store"
    echo
    echo "# Follow redirect to Cisco store:"
    echo "curl -H 'Host: boutique.cilium.rocks' -L http://$gateway_ip/redirect-to-cisco-store"
    echo
}

# Function to show canary deployment demo
show_canary_demo() {
    log_info "Canary Deployment Demo:"
    echo
    log_info "The checkout service is configured with traffic splitting:"
    log_info "- 90% of traffic goes to the stable version"
    log_info "- 10% of traffic goes to the canary version (for users with X-User-Type: beta header)"
    echo
    
    local gateway_ip
    gateway_ip=$(kubectl get gateway cisco-boutique-gateway -n ciscoboutique -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "<GATEWAY_IP>")
    
    log_info "Test canary routing:"
    echo "# Regular user (90% traffic):"
    echo "curl -H 'Host: boutique.cilium.rocks' http://$gateway_ip/api/checkout"
    echo
    echo "# Beta user (10% traffic to canary):"
    echo "curl -H 'Host: boutique.cilium.rocks' -H 'X-User-Type: beta' http://$gateway_ip/api/checkout"
    echo
    
    # Show HTTPS versions if CA is available
    local ca_root
    ca_root=$(mkcert -CAROOT 2>/dev/null || echo "")
    if [ -n "$ca_root" ] && [ -f "$ca_root/rootCA.pem" ]; then
        log_info "HTTPS versions (with proper certificate validation):"
        echo "# Regular user HTTPS:"
        echo "curl -s --resolve \"boutique.cilium.rocks:443:$gateway_ip\" \\"
        echo "     --cacert \"$ca_root/rootCA.pem\" \\"
        echo "     https://boutique.cilium.rocks/api/checkout"
        echo
        echo "# Beta user HTTPS:"
        echo "curl -s --resolve \"boutique.cilium.rocks:443:$gateway_ip\" \\"
        echo "     --cacert \"$ca_root/rootCA.pem\" \\"
        echo "     -H 'X-User-Type: beta' \\"
        echo "     https://boutique.cilium.rocks/api/checkout"
        echo
    fi
}

# Function to show Gateway API advantages
show_advantages() {
    log_info "Gateway API Advantages over Traditional Ingress:"
    echo
    echo "✅ Role-based separation (GatewayClass, Gateway, HTTPRoute)"
    echo "✅ Advanced traffic management (header-based routing, traffic splitting)"
    echo "✅ Multiple protocol support (HTTP, HTTPS, TCP, UDP)"
    echo "✅ Cross-namespace routing with proper RBAC"
    echo "✅ Request/response transformation"
    echo "✅ Rich status reporting and conditions"
    echo "✅ Vendor-neutral API with portable configurations"
    echo "✅ Advanced path matching (Exact, PathPrefix, RegularExpression)"
    echo "✅ Built-in support for canary deployments and A/B testing"
    echo
}

# Function to cleanup Gateway API resources
cleanup() {
    log_info "Cleaning up Gateway API resources..."
    
    if [ -f "$SCRIPT_DIR/gateway-api-example.yaml" ]; then
        kubectl delete -f "$SCRIPT_DIR/gateway-api-example.yaml" --ignore-not-found=true
        log_success "Gateway API resources cleaned up"
    else
        log_warning "gateway-api-example.yaml not found, skipping cleanup"
    fi
}

# Help function
show_help() {
    echo "Gateway API Demo Script for Cisco Boutique"
    echo
    echo "Usage: $0 [COMMAND]"
    echo
    echo "Commands:"
    echo "  deploy     Deploy Gateway API resources"
    echo "  status     Show Gateway API status"
    echo "  test       Test Gateway API routes"
    echo "  dns        Show DNS configuration instructions"
    echo "  canary     Show canary deployment demo"
    echo "  advantages Show Gateway API advantages"
    echo "  cleanup    Remove Gateway API resources"
    echo "  help       Show this help message"
    echo
    echo "Examples:"
    echo "  $0 deploy     # Deploy Gateway API configuration"
    echo "  $0 status     # Check Gateway and routes status"
    echo "  $0 test       # Show test commands for routes"
    echo
}

# Main execution based on command
case "${1:-deploy}" in
    "deploy")
        check_prerequisites
        check_gateway_api
        generate_certificate
        deploy_gateway_api
        sleep 5  # Wait for resources to be processed
        show_gateway_status
        get_gateway_ip && configure_local_dns
        show_advantages
        ;;
    "status")
        show_gateway_status
        get_gateway_ip
        ;;
    "test")
        test_routes
        ;;
    "dns")
        configure_local_dns
        ;;
    "canary")
        show_canary_demo
        ;;
    "advantages")
        show_advantages
        ;;
    "cleanup")
        cleanup
        ;;
    "help"|"-h"|"--help")
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac