# Cisco Boutique on Cilium

This guide walks you through setting up a Kubernetes cluster using Kind with Cilium as the CNI, Gateway API support, and deploying the Cisco Boutique microservices demo application.

## Prerequisites

- Docker installed and running
- `kind` CLI tool installed
- `kubectl` CLI tool installed
- `helm` CLI tool installed
- `cilium` CLI tool installed

## Architecture Overview

This setup creates:
- 3-node Kind cluster (1 control-plane, 2 workers)
- Cilium CNI with Gateway API support
- L2 announcement for LoadBalancer services
- Cisco Boutique microservices application
- Hubble for network observability

## About the Online Boutique Application

**Online Boutique** is a cloud-first microservices demo application. The application is a web-based e-commerce app where users can browse items, add them to the cart, and purchase them.

Google uses this application to demonstrate how developers can modernize enterprise applications using Google Cloud products, including: Google Kubernetes Engine (GKE), Cloud Service Mesh (CSM), gRPC, Cloud Operations, Spanner, Memorystore, AlloyDB, and Gemini. This application works on any Kubernetes cluster.

Online Boutique is composed of 11 microservices written in different languages that talk to each other over gRPC.

In this lab, we will deploy our own fork of the Google Online Boutique: the **Cisco Swag Store** !

### Goal for this Task

In this task you will deploy the Cisco Swag Store application onto your Kubernetes cluster:

We will then browse to the application and see what's happening.

### Application Microservices

| Service                                              | Language/Framework      | Description                                                                                                                       |
| ---------------------------------------------------- | ------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| frontend                          | Go            | Exposes an HTTP server to serve the website. Does not require signup/login and generates session IDs for all users automatically. |
| cartservice                    | C#            | Stores the items in the user's shopping cart in Redis and retrieves it.                                                           |
| productcatalogservice | Go            | Provides the list of products from a JSON file and ability to search products and get individual products.                        |
| currencyservice             | Node.js       | Converts one money amount to another currency. Uses real values fetched from European Central Bank. It's the highest QPS service. |
| paymentservice             | Node.js       | Charges the given credit card info (mock) with the given amount and returns a transaction ID.                                     |
| shippingservice             | Go            | Gives shipping cost estimates based on the shopping cart. Ships items to the given address (mock)                                 |
| emailservice                  | Python        | Sends users an order confirmation email (mock).                                                                                   |
| checkoutservice            | Go            | Retrieves user cart, prepares order and orchestrates the payment, shipping and the email notification.                            |
| recommendationservice | Python        | Recommends other products based on what's given in the cart.                                                                      |
| adservice                         | Java          | Provides text ads based on given context words.                                                                                   |
| loadgenerator                 | Python/Locust | Continuously sends requests imitating realistic user shopping flows to the frontend.                                              |

Here is a view at the overall architecture of this application:

![Online Boutique Frontend](https://github.com/ciscodocs/ltrcld-2397-clamer25/raw/main/docs/assets/online-boutique/architecture-diagram.png)

While this image was statically created, in the next task, you will see how we can use Isovalent Hubble to automatically create a service map!

## 🚀 Quick Start

For the fastest setup experience, use the automated script:

```bash
# Clone this repository
git clone <repository-url>
cd cisco-boutique-demo

# Run the complete setup
./setup-demo.sh

# (Optional) Deploy Gateway API example
./gateway-api-demo.sh deploy
```

## 🌐 Gateway API Example

This demo includes a comprehensive **Gateway API example** that showcases advanced traffic management capabilities as a modern replacement for traditional Ingress controllers.

### Gateway API Features Demonstrated:
- **Multi-domain routing** (boutique.cisco.local, api.boutique.cisco.local, admin.boutique.cisco.local)
- **Path-based routing** for microservices APIs
- **Traffic splitting** for canary deployments and A/B testing
- **Header-based routing** with request transformation
- **TLS termination** with HTTPS support
- **Health check endpoints** for monitoring

### Quick Gateway API Demo:
```bash
# Deploy Gateway API resources
./gateway-api-demo.sh deploy

# Configure local DNS
./gateway-api-demo.sh dns

# Test the routes
./gateway-api-demo.sh test

# View canary deployment demo
./gateway-api-demo.sh canary
```

📖 **For detailed Gateway API documentation, see [GATEWAY-API-EXAMPLE.md](GATEWAY-API-EXAMPLE.md)**

## Step-by-Step Manual Setup

### 1. Create Kind Cluster Configuration

Create a file named `kind.yaml` with the following configuration:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: kindest/node:v1.33.0
- role: worker
  image: kindest/node:v1.33.0
- role: worker
  image: kindest/node:v1.33.0
networking:
  disableDefaultCNI: true
```

### 2. Create the Kind Cluster

```bash
kind create cluster --config=kind.yaml
```

This creates a 3-node cluster with no default CNI (we'll install Cilium as our CNI).

### 3. Install Gateway API CRDs

Install the Gateway API Custom Resource Definitions:

```bash
CRD_PATH=https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/
kubectl apply -f "${CRD_PATH}/gateway.networking.k8s.io_gatewayclasses.yaml"
kubectl apply -f "${CRD_PATH}/gateway.networking.k8s.io_gateways.yaml"
kubectl apply -f "${CRD_PATH}/gateway.networking.k8s.io_httproutes.yaml"
kubectl apply -f "${CRD_PATH}/gateway.networking.k8s.io_referencegrants.yaml"
kubectl apply -f "${CRD_PATH}/gateway.networking.k8s.io_grpcroutes.yaml"
```

### 4. Create Cilium Values Configuration

Create a file named `cilium-gatewayapi-values.yaml`:

```yaml
kubeProxyReplacement: true
l2announcements:
  enabled: true
devices:
  - eth0
ipam:
  mode: kubernetes
gatewayAPI:
  enabled: true
```

### 5. Install Cilium with Gateway API Support

```bash
helm install cilium cilium/cilium --version 1.18.2 -n kube-system --values cilium-gatewayapi-values.yaml
```

### 6. Configure L2 Announcement Policy

Create and apply the L2 announcement policy for LoadBalancer services:

```yaml
apiVersion: "cilium.io/v2alpha1"
kind: CiliumL2AnnouncementPolicy
metadata:
  name: policy1
spec:
  loadBalancerIPs: true  
  interfaces:
  - eth0
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
```

Save this as `l2-announcement-policy.yaml` and apply:

```bash
kubectl apply -f l2-announcement-policy.yaml
```

### 7. Configure LoadBalancer IP Pool

Create and apply the IP pool for LoadBalancer services:

```yaml
apiVersion: "cilium.io/v2alpha1"
kind: CiliumLoadBalancerIPPool
metadata:
  name: "pool"
spec:
  blocks:
  - cidr: "172.18.255.200/29"
```

Save this as `loadbalancer-ip-pool.yaml` and apply:

```bash
kubectl apply -f loadbalancer-ip-pool.yaml
```

### 8. Deploy Cisco Boutique Application

Install the Cisco Boutique microservices demo using Helm:

```bash
helm upgrade --install onlineboutique oci://us-docker.pkg.dev/online-boutique-ci/charts/onlineboutique \
  --set images.repository=us-docker.pkg.dev/gcp-cpagcpdemosdwan-nprd-95534/microservices-demo \
  --set images.tag=102325-1 \
  --namespace ciscoboutique \
  --create-namespace
```

### 9. Enable Cilium Hubble for Network Observability

Enable Hubble UI for network observability and monitoring:

```bash
cilium hubble enable --ui
cilium status --wait
cilium hubble ui &
```

## Verification

### Check Cluster Status

```bash
kubectl get nodes
kubectl get pods -n kube-system
kubectl get pods -n ciscoboutique
```

### Verify Cilium Installation

```bash
cilium status
```

### Access Hubble UI

The Hubble UI should be accessible after running the hubble commands. Check the output for the URL or port forwarding information.

### Access Cisco Boutique

Check the LoadBalancer service to get the external IP:

```bash
kubectl get svc -n ciscoboutique
```

### Bonus Task

Using your IDE and a MCP Server for Kubernetes, ask Co-Pilot (or the agentic AI of your choice) for information about your cluster, the application running in it and, using Hubble logs, to extrapolate relevant network policies.

**Important**: For the MCP server to access Hubble observability data, you need to forward the Hubble relay port to your local machine:

```bash
cilium hubble port-forward &
```

## Troubleshooting

### Common Issues

1. **Pods stuck in Pending**: Check if Cilium is properly installed and all nodes are ready
2. **LoadBalancer External IP pending**: Verify L2 announcement policy and IP pool are correctly applied
3. **Gateway API not working**: Ensure CRDs are installed and Cilium Gateway API is enabled

### Useful Commands

```bash
# Check Cilium status
cilium status

```

## Cleanup

To tear down the environment:

```bash
kind delete cluster kind
```

## Key Features

- **Cilium CNI**: Advanced networking with eBPF
- **Gateway API**: Modern ingress/gateway management
- **L2 Announcements**: LoadBalancer support in Kind
- **Hubble**: Network observability and monitoring
- **Microservices Demo**: Real-world application example

## Architecture Benefits

- **No kube-proxy**: Cilium replaces kube-proxy for better performance
- **eBPF networking**: Advanced networking capabilities
- **Gateway API**: Future-proof ingress management
- **Network policies**: Advanced security policies with Cilium
- **Observability**: Deep network insights with Hubble