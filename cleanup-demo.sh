#!/bin/bash

# Cisco Boutique Demo Cleanup Script
# This script removes the Kind cluster and cleans up the demo environment

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="kind"

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

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to stop background processes
stop_background_processes() {
    log_info "Stopping any running Hubble UI processes..."
    
    # Kill any running cilium hubble ui processes
    if pgrep -f "cilium hubble ui" > /dev/null; then
        log_warning "Found running Hubble UI processes. Stopping them..."
        pkill -f "cilium hubble ui" || true
        sleep 2
    fi
    
    # Kill any kubectl port-forward processes for hubble
    if pgrep -f "kubectl.*port-forward.*hubble" > /dev/null; then
        log_warning "Found running Hubble port-forward processes. Stopping them..."
        pkill -f "kubectl.*port-forward.*hubble" || true
        sleep 2
    fi
}

# Function to cleanup FRR container
cleanup_frr_container() {
    log_info "Stopping FRR router container..."

    if docker ps -a --format '{{.Names}}' | grep -q "^frr$"; then
        docker rm -f frr &>/dev/null || true
        log_success "FRR container removed"
    else
        log_warning "No FRR container found"
    fi
}

# Function to cleanup Kind cluster
cleanup_cluster() {
    if ! command_exists kind; then
        log_error "Kind CLI not found. Cannot cleanup cluster."
        return 1
    fi
    
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        log_info "Deleting Kind cluster '${CLUSTER_NAME}'..."
        kind delete cluster --name "$CLUSTER_NAME"
        log_success "Kind cluster '${CLUSTER_NAME}' deleted successfully"
    else
        log_warning "No Kind cluster '${CLUSTER_NAME}' found"
    fi
}

# Function to cleanup Docker resources
cleanup_docker() {
    log_info "Cleaning up Docker resources..."
    
    # Remove any dangling Docker networks created by Kind
    local networks=$(docker network ls --filter "name=kind" --format "{{.Name}}" 2>/dev/null || true)
    if [ -n "$networks" ]; then
        log_info "Removing Kind Docker networks..."
        echo "$networks" | xargs -r docker network rm 2>/dev/null || true
    fi
    
    # Prune any dangling volumes (be careful with this)
    read -p "Do you want to clean up dangling Docker volumes? This might affect other Docker projects. (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Cleaning up dangling Docker volumes..."
        docker volume prune -f || true
    fi
    
    log_success "Docker cleanup completed"
}

# Function to remove local kubectl context
cleanup_kubectl_context() {
    log_info "Cleaning up kubectl context..."
    
    # Remove the kind cluster context
    if kubectl config get-contexts -o name | grep -q "kind-${CLUSTER_NAME}"; then
        kubectl config delete-context "kind-${CLUSTER_NAME}" 2>/dev/null || true
        log_success "Removed kubectl context 'kind-${CLUSTER_NAME}'"
    fi
    
    # Remove the kind cluster config
    if kubectl config get-clusters | grep -q "kind-${CLUSTER_NAME}"; then
        kubectl config delete-cluster "kind-${CLUSTER_NAME}" 2>/dev/null || true
        log_success "Removed kubectl cluster config 'kind-${CLUSTER_NAME}'"
    fi
    
    # Remove the kind user
    if kubectl config get-users | grep -q "kind-${CLUSTER_NAME}"; then
        kubectl config delete-user "kind-${CLUSTER_NAME}" 2>/dev/null || true
        log_success "Removed kubectl user 'kind-${CLUSTER_NAME}'"
    fi
}

# Function to show cleanup summary
show_cleanup_summary() {
    echo
    log_success "Cleanup completed!"
    echo
    log_info "What was cleaned up:"
    echo "  ✓ FRR router container"
    echo "  ✓ Kind cluster '${CLUSTER_NAME}'"
    echo "  ✓ Kubernetes context and config"
    echo "  ✓ Background processes (Hubble UI, port-forwards)"
    echo "  ✓ Kind Docker networks"
    echo
    log_info "If you want to completely clean up Docker:"
    echo "  docker system prune -a  # Remove all unused Docker resources"
    echo
}

# Main execution
main() {
    echo
    log_info "Starting Cisco Boutique Demo Cleanup"
    echo "======================================"
    echo
    
    # Confirm cleanup
    log_warning "This will delete the Kind cluster and cleanup all demo resources."
    read -p "Are you sure you want to proceed? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cleanup cancelled"
        exit 0
    fi
    
    stop_background_processes
    cleanup_frr_container
    cleanup_cluster
    cleanup_kubectl_context
    cleanup_docker
    show_cleanup_summary
    
    log_success "Cisco Boutique Demo cleanup completed successfully!"
}

# Execute main function
main "$@"