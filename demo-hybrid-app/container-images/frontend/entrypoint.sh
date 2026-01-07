#!/bin/bash
set -e

# Get DNS resolver from /etc/resolv.conf (first nameserver)
DNS_RESOLVER=$(grep nameserver /etc/resolv.conf | head -1 | awk '{print $2}')
if [ -z "$DNS_RESOLVER" ]; then
    # Fallback to common Kubernetes DNS IPs
    DNS_RESOLVER="10.96.0.10"
fi

# Get backend service name from environment variable, default to "backend"
BACKEND_SERVICE="${BACKEND_SERVICE_NAME:-backend}"
BACKEND_PORT="${BACKEND_SERVICE_PORT:-8000}"

# Get namespace from pod metadata or environment
NAMESPACE="${POD_NAMESPACE:-$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo 'default')}"

# Construct FQDN for better DNS resolution
BACKEND_FQDN="${BACKEND_SERVICE}.${NAMESPACE}.svc.cluster.local"

# Generate nginx server config with runtime values
cat > /etc/nginx/conf.d/default.conf <<EOF
server {
    listen 8080;
    server_name _;

    root /opt/app-root/src;
    index index.html;

    # Serve static files
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Proxy API requests to backend service
    # Using variable forces runtime DNS resolution instead of startup resolution
    # Resolver must be in location block when using variables in proxy_pass
    location /api {
        resolver ${DNS_RESOLVER} valid=10s;
        set \$backend "http://${BACKEND_FQDN}:${BACKEND_PORT}";
        proxy_pass \$backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_connect_timeout 5s;
        proxy_send_timeout 10s;
        proxy_read_timeout 10s;
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;
        proxy_next_upstream_tries 2;
    }

    # Health check endpoint
    location /healthz {
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF

# Update main nginx config with DNS resolver
# Read the config, replace resolver line, and write directly
sed "s/resolver .*/resolver ${DNS_RESOLVER} valid=10s;/" /etc/nginx/nginx.conf > /tmp/nginx.conf.tmp
cat /tmp/nginx.conf.tmp > /etc/nginx/nginx.conf
rm -f /tmp/nginx.conf.tmp

exec nginx -g "daemon off;"

