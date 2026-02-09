# Gateway API Example for Cisco Boutique Demo

This example demonstrates how Gateway API serves as a powerful replacement for traditional Ingress controllers, showcasing advanced traffic management capabilities with the Cisco Boutique microservices application.

## 🎯 What This Example Demonstrates

### Core Gateway API Concepts
1. **GatewayClass** - Defines the controller implementation (Cilium)
2. **Gateway** - Represents the load balancer infrastructure
3. **HTTPRoute** - Defines routing rules and traffic policies

### Advanced Features Showcased
- **Multi-domain routing** with different hostnames
- **Path-based routing** for API endpoints
- **Traffic splitting** for canary deployments
- **Header-based routing** for A/B testing
- **Request transformation** with header modification
- **TLS termination** with HTTPS support
- **Cross-service routing** for microservices

## 🏗️ Architecture Overview

```
                                 ┌─────────────────────┐
                                 │   Gateway API       │
                                 │   Configuration     │
                                 └─────────────────────┘
                                           │
                    ┌──────────────────────┼──────────────────────┐
                    │                      │                      │
            ┌───────▼───────┐    ┌────────▼────────┐    ┌───────▼───────┐
            │ GatewayClass   │    │     Gateway     │    │   HTTPRoutes  │
            │   (cilium)     │    │ (LoadBalancer)  │    │ (Routing Rules)│
            └────────────────┘    └─────────────────┘    └───────────────┘
                                           │
                                 ┌────────▼────────┐
                                 │ Cilium Gateway  │
                                 │   Controller    │
                                 └─────────────────┘
                                           │
              ┌────────────────────────────┼────────────────────────────┐
              │                            │                            │
    ┌────────▼────────┐         ┌─────────▼─────────┐       ┌─────────▼─────────┐
    │  Frontend App   │         │    API Services   │       │   Admin/Health    │
    │ boutique.cisco  │         │ api.boutique.cisco│       │admin.boutique.cisco│
    └─────────────────┘         └───────────────────┘       └───────────────────┘
```

## 🚀 Quick Start

1. **Deploy your Cisco Boutique environment:**
   ```bash
   ./setup-demo.sh
   ```

2. **Generate wildcard certificate (if mkcert not installed: `brew install mkcert`):**
   ```bash
   mkcert '*.cilium.rocks'
   ```

2. **Generate wildcard certificate (if mkcert not installed: `brew install mkcert`):**
   ```bash
   mkcert '*.cilium.rocks'
   ```

3. **Deploy Gateway API resources:**
   ```bash
   ./gateway-api-demo.sh deploy
   ```

4. **Configure local DNS (add to /etc/hosts):**
   ```bash
   ./gateway-api-demo.sh dns
   ```

5. **Test the routes:**
   ```bash
   ./gateway-api-demo.sh test
   ```

## 📋 Detailed Route Configuration

### 1. Main Frontend Route
- **Hostname:** `boutique.cilium.rocks`, `www.boutique.cilium.rocks`
- **Path:** `/` (all traffic)
- **Backend:** `frontend` service
- **Purpose:** Main application entry point

### 2. API Microservices Routes
- **Hostname:** `api.boutique.cilium.rocks`
- **Paths:**
  - `/api/products` → `productcatalogservice`
  - `/api/currency` → `currencyservice`
  - `/api/recommendations` → `recommendationservice`
  - `/api/cart` → `cartservice`
- **Purpose:** Direct API access to individual microservices

### 3. Canary Deployment Route
- **Hostname:** `boutique.cilium.rocks`
- **Path:** `/api/checkout`
- **Traffic Splitting:**
  - Users with `X-User-Type: beta` header → 10% canary traffic
  - Regular users → 90% stable traffic
- **Purpose:** A/B testing and gradual rollouts

### 4. Admin Interface Route
- **Hostname:** `admin.boutique.cilium.rocks`
- **Path:** `/admin`
- **Features:**
  - Request header modification
  - Adds `X-Admin-Access: granted` header
  - Adds `X-Request-ID` for tracking
- **Purpose:** Demonstrate request transformation

### 5. Health Check Routes
- **Hostname:** `health.boutique.cilium.rocks`
- **Paths:**
  - `/health/frontend` → frontend health
  - `/health/cart` → cart service health
  - `/health/checkout` → checkout service health
- **Purpose:** Service monitoring and health checks

### 6. Legal Compliance Redirect
- **Hostname:** `boutique.cilium.rocks`
- **Path:** `/redirect-to-cisco-store`
- **Action:** Redirects to `https://merchandise-eu.cisco.com/` (root path)
- **Status Code:** 301 (Permanent Redirect)
- **Path Handling:** Clears original path and redirects to root
- **Purpose:** Compliance with legal requirements for secure shopping

## 🧪 Testing Examples

### Basic Frontend Access
```bash
# Direct IP access
curl -H 'Host: boutique.cilium.rocks' http://<GATEWAY_IP>/

# With proper DNS configuration and HTTPS
curl --resolve "boutique.cilium.rocks:443:<GATEWAY_IP>" \
     --cacert "$(mkcert -CAROOT)/rootCA.pem" \
     https://boutique.cilium.rocks/
```

### API Microservices
```bash
# Product catalog
curl -H 'Host: api.boutique.cilium.rocks' http://<GATEWAY_IP>/api/products

# Currency service
curl -H 'Host: api.boutique.cilium.rocks' http://<GATEWAY_IP>/api/currency

# Recommendations
curl -H 'Host: api.boutique.cilium.rocks' http://<GATEWAY_IP>/api/recommendations
```

### Canary Deployment Testing
```bash
# Regular user (stable version)
curl -H 'Host: boutique.cilium.rocks' http://<GATEWAY_IP>/api/checkout

# Beta user (canary version)
curl -H 'Host: boutique.cilium.rocks' \
     -H 'X-User-Type: beta' \
     http://<GATEWAY_IP>/api/checkout
```

### Admin Interface with Header Modification
```bash
# Admin access (headers will be automatically added)
curl -H 'Host: admin.boutique.cilium.rocks' http://<GATEWAY_IP>/admin
```

### Health Checks
```bash
# Individual service health
curl -H 'Host: health.boutique.cilium.rocks' http://<GATEWAY_IP>/health/frontend
curl -H 'Host: health.boutique.cilium.rocks' http://<GATEWAY_IP>/health/cart
curl -H 'Host: health.boutique.cilium.rocks' http://<GATEWAY_IP>/health/checkout
```

### Legal Compliance Redirect (The Cheeky Example!)
```bash
# Test redirect to Cisco store (should return 301)
curl -H 'Host: boutique.cilium.rocks' -I http://<GATEWAY_IP>/redirect-to-cisco-store

# Follow redirect to see final destination
curl -H 'Host: boutique.cilium.rocks' -L http://<GATEWAY_IP>/redirect-to-cisco-store

# Expected result: Redirected to https://merchandise-eu.cisco.com/ (root page)/ (root page)

# For browser testing (after adding /etc/hosts entry):
# http://boutique.cilium.rocks/redirect-to-cisco-store
# 
# Or test directly with IP (thanks to IP-based route):
# http://<GATEWAY_IP>/redirect-to-cisco-store
```

## 🔧 Management Commands

### Deploy Gateway API
```bash
./gateway-api-demo.sh deploy
```

### Check Status
```bash
./gateway-api-demo.sh status
```

### Show DNS Configuration
```bash
./gateway-api-demo.sh dns
```

### Test Routes
```bash
./gateway-api-demo.sh test
```

### Show Canary Demo
```bash
./gateway-api-demo.sh canary
```

### Cleanup
```bash
./gateway-api-demo.sh cleanup
```

## 🆚 Gateway API vs Traditional Ingress

| Feature | Traditional Ingress | Gateway API |
|---------|-------------------|-------------|
| **Role Separation** | Limited | ✅ GatewayClass, Gateway, Route separation |
| **Multi-Protocol** | HTTP/HTTPS only | ✅ HTTP, HTTPS, TCP, UDP, gRPC |
| **Traffic Splitting** | Extension-specific | ✅ Native support |
| **Header Modification** | Controller-specific | ✅ Standardized filters |
| **Cross-Namespace** | Limited | ✅ Built-in with proper RBAC |
| **Status Reporting** | Basic | ✅ Rich conditions and status |
| **Vendor Portability** | Limited | ✅ Standard API across vendors |
| **Advanced Matching** | Path prefix only | ✅ Exact, prefix, regex, headers |

## 🛡️ Security Features

### TLS Termination
- HTTPS listener on port 443
- Certificate management with Kubernetes secrets
- Automatic redirect from HTTP to HTTPS (configurable)

### Header-based Security
- Admin access control with custom headers
- Request ID injection for audit trails
- User type identification for feature flags

### Cross-Namespace Isolation
- Proper RBAC with ReferenceGrant resources
- Namespace-scoped routing rules
- Secure service discovery

## 🔍 Observability Integration

### Cilium Hubble Integration
The Gateway API routes are fully integrated with Cilium's Hubble observability:

```bash
# Start Hubble UI
cilium hubble ui

# Port forward for external access
cilium hubble port-forward
```

### Monitoring Routes
- Gateway status and conditions
- HTTPRoute backend health
- Traffic distribution metrics
- Request/response transformations

## 🎓 Learning Outcomes

After running this example, you'll understand:

1. **Gateway API Architecture** - How GatewayClass, Gateway, and Routes work together
2. **Advanced Routing** - Path-based, header-based, and hostname-based routing
3. **Traffic Management** - Canary deployments, A/B testing, traffic splitting
4. **Request Transformation** - Header modification and request/response filters
5. **Multi-Protocol Support** - HTTP/HTTPS with TLS termination
6. **Observability** - Integration with service mesh observability tools
7. **Security** - TLS, RBAC, and cross-namespace access control

## 🔧 Customization

### Adding New Routes
1. Create new HTTPRoute resources in the YAML
2. Define appropriate hostnames and path matching
3. Configure backend services and weights
4. Apply filters for transformation if needed

### Traffic Policies
- Modify weight distribution for canary deployments
- Add new header-based routing rules
- Implement timeout and retry policies
- Configure rate limiting (controller-specific)

### TLS Configuration
- Replace dummy certificates with real ones
- Use cert-manager for automatic certificate management
- Configure SNI for multiple domains
- Implement client certificate authentication

This example provides a comprehensive foundation for understanding Gateway API capabilities and serves as a starting point for more advanced traffic management scenarios.

## 🐛 Troubleshooting

### Browser Redirect Not Working?

**Problem**: Accessing `http://<GATEWAY_IP>/redirect-to-cisco-store` in your browser doesn't redirect.

**Cause**: Gateway API HTTPRoutes use hostname-based routing. When you access the IP directly, the browser sends `Host: <IP>` instead of `Host: boutique.cilium.rocks`, so the route doesn't match.

**Solutions**:

1. **Add /etc/hosts entry (Recommended)**:
   ```bash
   echo "<GATEWAY_IP> boutique.cilium.rocks www.boutique.cilium.rocks" | sudo tee -a /etc/hosts
   ```
   Then use: `http://boutique.cilium.rocks/redirect-to-cisco-store`

2. **Use IP-based route**: The configuration includes an IP-based HTTPRoute that matches any hostname, so direct IP access should work after redeploying:
   ```bash
   ./gateway-api-demo.sh deploy
   ```

3. **Use browser developer tools**: Set a custom `Host` header in your browser's developer console.

### curl vs Browser Behavior
- **curl**: Can set custom `Host` headers with `-H 'Host: hostname'`
- **Browser**: Uses the URL's hostname/IP as the `Host` header automatically
- **Gateway API**: Routes based on the `Host` header, not the destination IP