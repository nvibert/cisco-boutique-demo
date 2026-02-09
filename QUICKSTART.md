# Quick Start Guide

This directory contains automated scripts to build and cleanup the Cisco Boutique demo environment.

## Files

- `setup-demo.sh` - Main automation script that builds the entire demo from start to finish
- `cleanup-demo.sh` - Script to completely cleanup the demo environment
- `kind.yaml` - Kind cluster configuration
- `cilium-gatewayapi-values.yaml` - Cilium installation values
- `l2-announcement-policy.yaml` - L2 announcement policy for LoadBalancer services
- `loadbalancer-ip-pool.yaml` - IP pool configuration for LoadBalancer services

## Quick Setup

### Prerequisites

Make sure you have the following tools installed:
- Docker (running)
- kind CLI
- kubectl CLI  
- helm CLI
- cilium CLI

### Run the Demo

1. **Setup the complete environment:**
   ```bash
   ./setup-demo.sh
   ```
   
   This script will:
   - Check all prerequisites
   - Create a 3-node Kind cluster
   - Install Gateway API CRDs
   - Install Cilium with Gateway API support
   - Configure L2 announcements and LoadBalancer IP pool
   - Deploy the Cisco Boutique application
   - Enable Hubble for network observability
   - Verify the deployment

2. **Access the application:**
   - The script will display the LoadBalancer IP at the end
   - Access the Cisco Boutique at: `http://<LoadBalancer-IP>`
   - Access Hubble UI: `cilium hubble ui`

### Cleanup

When you're done with the demo:

```bash
./cleanup-demo.sh
```

This will remove the Kind cluster and cleanup all resources.

## Manual Commands

If you prefer to run commands manually, see the detailed steps in `README.md`.

## Troubleshooting

### Common Issues

1. **Prerequisites missing**: Run the setup script - it will tell you what's missing
2. **Docker not running**: Start Docker Desktop/daemon before running the script
3. **Existing cluster conflicts**: The script will prompt you to delete existing clusters
4. **Pods not starting**: Check logs with `kubectl logs <pod-name> -n <namespace>`

### Useful Commands

```bash
# Check cluster status
kubectl get nodes
kubectl get pods -n ciscoboutique

# Check Cilium status
cilium status

# Check services and LoadBalancer IPs
kubectl get svc -n ciscoboutique

# View Hubble UI
cilium hubble ui

# Port forward Hubble for MCP server access
cilium hubble port-forward
```

## Script Features

### Setup Script (`setup-demo.sh`)

- ✅ Prerequisite validation
- ✅ Existing cluster detection and cleanup
- ✅ Automated error handling
- ✅ Progress logging with colors
- ✅ Pod readiness waiting
- ✅ Deployment verification
- ✅ Access information display

### Cleanup Script (`cleanup-demo.sh`)

- ✅ Safe cleanup confirmation
- ✅ Background process termination
- ✅ Complete cluster removal
- ✅ kubectl context cleanup
- ✅ Docker network cleanup
- ✅ Optional volume cleanup

## Customization

You can modify the configuration files to customize the setup:

- `kind.yaml` - Change node count or Kubernetes version
- `cilium-gatewayapi-values.yaml` - Modify Cilium features
- `loadbalancer-ip-pool.yaml` - Change IP range for LoadBalancer services

After modifying, just run `./setup-demo.sh` again.