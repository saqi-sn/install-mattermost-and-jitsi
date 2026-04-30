#!/bin/bash

################################################################################
# Mattermost + Jitsi Installation Script for Ubuntu (Iranian Mirrors)
# Supports Ubuntu 20.04, 22.04, 24.04 LTS
# Author: Ali Sahafi
# Version: 1.0
################################################################################

set -e  # Exit on error (we'll handle errors manually)

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log file
LOG_FILE="/var/log/mattermost-jitsi-setup.log"
CREDENTIALS_FILE="/root/mattermost-jitsi-credentials.txt"

# Configuration variables
INSTALL_JITSI=""
MATTERMOST_DOMAIN=""
JITSI_DOMAIN=""
NEED_SSL=""
SSL_METHOD=""
MATTERMOST_ADMIN_EMAIL=""
MATTERMOST_ADMIN_USERNAME=""
MATTERMOST_ADMIN_PASSWORD=""
DB_PASSWORD=""
MATTERMOST_DB_USER="mmuser"
MATTERMOST_DB_NAME="mattermost"
POSTGRES_PASSWORD=""

# Jitsi passwords
JICOFO_AUTH_PASSWORD=""
JICOFO_COMPONENT_SECRET=""
JVB_AUTH_PASSWORD=""
JIBRI_RECORDER_PASSWORD=""
JIBRI_XMPP_PASSWORD=""

# Paths
INSTALL_DIR="/opt/mattermost-jitsi"
NGINX_CONF_DIR="/etc/nginx"
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"

################################################################################
# Utility Functions
################################################################################

# Print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

# Generate random password
generate_password() {
    local length=${1:-20}
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-${length}
}

# Retry function with exponential backoff
retry_command() {
    local max_attempts=3
    local timeout=1
    local attempt=1
    local exitCode=0

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        else
            exitCode=$?
        fi

        if [ $attempt -lt $max_attempts ]; then
            print_warning "Command failed. Attempt $attempt/$max_attempts. Retrying in ${timeout}s..."
            sleep $timeout
            timeout=$((timeout * 2))
        fi
        attempt=$((attempt + 1))
    done

    print_error "Command failed after $max_attempts attempts: $*"
    return $exitCode
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Validate domain format
validate_domain() {
    local domain=$1
    if [[ $domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    else
        return 1
    fi
}

# Check DNS resolution
check_dns() {
    local domain=$1
    print_status "Checking DNS resolution for $domain..."
    if host "$domain" >/dev/null 2>&1; then
        local ip=$(host "$domain" | grep "has address" | head -1 | awk '{print $4}')
        print_success "Domain $domain resolves to $ip"
        return 0
    else
        print_warning "Domain $domain does not resolve. Please ensure DNS is configured."
        return 1
    fi
}

################################################################################
# System Checks
################################################################################

check_system_requirements() {
    print_status "Checking system requirements..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then 
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Check Ubuntu version
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "ubuntu" ]; then
            print_error "This script only supports Ubuntu"
            exit 1
        fi
        
        case "$VERSION_ID" in
            20.04|22.04|24.04)
                print_success "Ubuntu $VERSION_ID detected"
                UBUNTU_RELEASE=$(lsb_release -cs)
                ;;
            *)
                print_error "Unsupported Ubuntu version: $VERSION_ID"
                print_error "This script supports Ubuntu 20.04, 22.04, and 24.04 LTS"
                exit 1
                ;;
        esac
    else
        print_error "Cannot detect OS version"
        exit 1
    fi
    
    # Check RAM
    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$total_ram" -lt 3800 ]; then
        print_warning "System has ${total_ram}MB RAM. Recommended: 4GB+ for Mattermost"
        if [ "$INSTALL_JITSI" = "yes" ]; then
            print_warning "With Jitsi, 8GB+ RAM is strongly recommended"
        fi
        read -p "Continue anyway? (yes/no): " continue_anyway
        if [ "$continue_anyway" != "yes" ]; then
            print_error "Installation cancelled by user"
            exit 1
        fi
    else
        print_success "RAM check passed: ${total_ram}MB"
    fi
    
    # Check CPU cores
    cpu_cores=$(nproc)
    if [ "$cpu_cores" -lt 2 ]; then
        print_warning "System has ${cpu_cores} CPU core(s). Recommended: 2+ cores"
        read -p "Continue anyway? (yes/no): " continue_anyway
        if [ "$continue_anyway" != "yes" ]; then
            print_error "Installation cancelled by user"
            exit 1
        fi
    else
        print_success "CPU check passed: ${cpu_cores} cores"
    fi
    
    # Check disk space
    available_space=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$available_space" -lt 20 ]; then
        print_warning "Available disk space: ${available_space}GB. Recommended: 20GB+"
        read -p "Continue anyway? (yes/no): " continue_anyway
        if [ "$continue_anyway" != "yes" ]; then
            print_error "Installation cancelled by user"
            exit 1
        fi
    else
        print_success "Disk space check passed: ${available_space}GB available"
    fi
}

################################################################################
# DNS Configuration
################################################################################

configure_dns() {
    print_status "Configuring DNS servers..."
    
    # Backup existing DNS configuration
    if [ -f /etc/systemd/resolved.conf ]; then
        cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.backup
        print_success "Backed up /etc/systemd/resolved.conf"
    fi
    
    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf /etc/resolv.conf.backup
        print_success "Backed up /etc/resolv.conf"
    fi
    
    # Configure systemd-resolved (Ubuntu 18.04+)
    if systemctl is-active --quiet systemd-resolved; then
        print_status "Configuring systemd-resolved..."
        cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=217.218.127.127 217.218.155.155
FallbackDNS=8.8.8.8 8.8.4.4
EOF
        
        systemctl restart systemd-resolved
        print_success "systemd-resolved configured and restarted"
    else
        # Fallback to /etc/resolv.conf
        print_status "Configuring /etc/resolv.conf..."
        cat > /etc/resolv.conf <<EOF
nameserver 217.218.127.127
nameserver 217.218.155.155
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
        
        # Make it immutable to prevent overwriting
        chattr +i /etc/resolv.conf
        print_success "/etc/resolv.conf configured"
    fi
    
    print_success "DNS configuration completed"
}

################################################################################
# Repository Configuration
################################################################################

configure_repositories() {
    print_status "Configuring Ubuntu repositories..."
    
    # Backup original sources.list
    if [ -f /etc/apt/sources.list ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.backup
        print_success "Backed up /etc/apt/sources.list"
    fi
    
    # Create new sources.list with Iranian mirrors
    cat > /etc/apt/sources.list <<EOF
# Iranian Mirror - ArvanCloud
deb http://mirror.arvancloud.ir/ubuntu ${UBUNTU_RELEASE} main restricted universe multiverse
deb http://mirror.arvancloud.ir/ubuntu ${UBUNTU_RELEASE}-updates main restricted universe multiverse
deb http://mirror.arvancloud.ir/ubuntu ${UBUNTU_RELEASE}-security main restricted universe multiverse
deb http://mirror.arvancloud.ir/ubuntu ${UBUNTU_RELEASE}-backports main restricted universe multiverse

# Fallback to main Ubuntu mirrors
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_RELEASE} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_RELEASE}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${UBUNTU_RELEASE}-security main restricted universe multiverse
EOF
    
    print_success "Repository configuration completed"
    
    # Update package list
    print_status "Updating package lists..."
    retry_command apt-get update || {
        print_warning "Failed to update from Iranian mirrors, trying main mirrors only..."
        cat > /etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_RELEASE} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_RELEASE}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${UBUNTU_RELEASE}-security main restricted universe multiverse
EOF
        apt-get update
    }
    
    print_success "Package lists updated"
}

################################################################################
# Docker Installation
################################################################################

install_docker() {
    print_status "Installing Docker..."
    
    # Check if Docker is already installed
    if command_exists docker; then
        print_warning "Docker is already installed"
        docker --version | tee -a "$LOG_FILE"
        read -p "Reinstall Docker? (yes/no): " reinstall
        if [ "$reinstall" != "yes" ]; then
            print_status "Skipping Docker installation"
            return 0
        fi
    fi
    
    # Install prerequisites
    print_status "Installing prerequisites..."
    retry_command apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common
    
    # Try docker.io from Ubuntu repos first (simplest)
    print_status "Attempting to install docker.io from Ubuntu repositories..."
    apt-get update
    if apt-get install -y docker.io; then
        print_success "Docker (docker.io) installed from Ubuntu repositories"
    else
        print_warning "Failed to install docker.io, trying Docker CE from Iranian mirror..."
        
        # Clean up any keyring if exists
        rm -f /usr/share/keyrings/docker-archive-keyring.gpg
        
        # Try Iranian mirror (kernel.ir)
        print_status "Attempting to install Docker CE from Iranian mirror..."
        if curl -fsSL https://mirror.kernel.ir/docker/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg 2>/dev/null; then
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirror.kernel.ir/docker/linux/ubuntu ${UBUNTU_RELEASE} stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            apt-get update
            
            if apt-get install -y docker-ce docker-ce-cli containerd.io; then
                print_success "Docker CE installed from Iranian mirror"
            else
                print_warning "Failed to install from Iranian mirror, trying official Docker repository..."
                rm -f /etc/apt/sources.list.d/docker.list
                rm -f /usr/share/keyrings/docker-archive-keyring.gpg
            fi
        fi
        
        # Fallback to official Docker repository
        if ! command_exists docker; then
            print_status "Installing Docker CE from official repository..."
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_RELEASE} stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            apt-get update
            retry_command apt-get install -y docker-ce docker-ce-cli containerd.io
            print_success "Docker CE installed from official repository"
        fi
    fi
    
    # Verify Docker installation
    if ! command_exists docker; then
        print_error "Docker installation failed"
        exit 1
    fi
    
    # Start and enable Docker
    systemctl start docker
    systemctl enable docker
    print_success "Docker service started and enabled"
    
    # Add current user to docker group (if not root)
    if [ -n "$SUDO_USER" ]; then
        usermod -aG docker "$SUDO_USER"
        print_success "Added $SUDO_USER to docker group"
    fi
}

install_docker_compose() {
    print_status "Installing Docker Compose..."
    
    # Try docker compose plugin first (v2)
    if docker compose version >/dev/null 2>&1; then
        print_success "Docker Compose plugin already installed"
        docker compose version | tee -a "$LOG_FILE"
        return 0
    fi
    
    # Try installing docker-compose-plugin
    print_status "Attempting to install docker-compose-plugin..."
    if apt-get install -y docker-compose-plugin 2>/dev/null; then
        if docker compose version >/dev/null 2>&1; then
            print_success "Docker Compose plugin installed"
            docker compose version | tee -a "$LOG_FILE"
            return 0
        fi
    fi
    
    # Fallback to docker-compose (v1)
    print_status "Attempting to install docker-compose (standalone)..."
    if apt-get install -y docker-compose 2>/dev/null; then
        if command_exists docker-compose; then
            print_success "Docker Compose (v1) installed"
            docker-compose --version | tee -a "$LOG_FILE"
            
            # Create alias for docker compose
            echo 'alias docker compose="docker-compose"' >> /root/.bashrc
            return 0
        fi
    fi
    
    # Last resort: download docker-compose binary
    print_status "Downloading docker-compose binary..."
    COMPOSE_VERSION="1.29.2"
    curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    
    if command_exists docker-compose; then
        print_success "Docker Compose binary installed"
        docker-compose --version | tee -a "$LOG_FILE"
        return 0
    fi
    
    print_error "Failed to install Docker Compose"
    exit 1
}

configure_docker_daemon() {
    print_status "Configuring Docker daemon for Iranian mirrors..."
    
    # Backup existing daemon.json if it exists
    if [ -f "$DOCKER_DAEMON_JSON" ]; then
        cp "$DOCKER_DAEMON_JSON" "${DOCKER_DAEMON_JSON}.backup"
        print_success "Backed up existing daemon.json"
    fi
    
    # Create daemon.json with Iranian mirrors
    cat > "$DOCKER_DAEMON_JSON" <<EOF
{
  "insecure-registries": ["https://docker.arvancloud.ir"],
  "registry-mirrors": ["https://docker.arvancloud.ir"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    
    print_success "Docker daemon configuration created"
    
    # Restart Docker daemon
    print_status "Restarting Docker daemon..."
    systemctl daemon-reload
    systemctl restart docker
    
    # Verify Docker is running
    if systemctl is-active --quiet docker; then
        print_success "Docker daemon restarted successfully"
    else
        print_error "Docker daemon failed to start"
        exit 1
    fi
}

################################################################################
# Firewall Configuration
################################################################################

configure_firewall() {
    print_status "Configuring UFW firewall..."
    
    # Install UFW if not present
    if ! command_exists ufw; then
        apt-get install -y ufw
    fi
    
    # Configure UFW
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH
    ufw allow 22/tcp comment 'SSH'
    
    # Allow HTTP and HTTPS
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    
    # Allow Jitsi UDP port if Jitsi is being installed
    if [ "$INSTALL_JITSI" = "yes" ]; then
        ufw allow 10000/udp comment 'Jitsi Video Bridge'
    fi
    
    # Enable UFW
    ufw --force enable
    
    print_success "Firewall configured and enabled"
    ufw status | tee -a "$LOG_FILE"
}

################################################################################
# NGINX Installation and Configuration
################################################################################

install_nginx() {
    print_status "Installing NGINX..."
    
    retry_command apt-get install -y nginx
    
    # Create necessary cache directories
    mkdir -p /var/cache/nginx
    mkdir -p /var/www/html
    chown -R www-data:www-data /var/cache/nginx
    chown -R www-data:www-data /var/www/html
    
    systemctl start nginx
    systemctl enable nginx
    
    print_success "NGINX installed and started"
}

configure_nginx_mattermost() {
    print_status "Configuring NGINX for Mattermost..."
    
    # Create cache directory
    mkdir -p /var/cache/nginx/mattermost
    chown -R www-data:www-data /var/cache/nginx/mattermost
    chmod 755 /var/cache/nginx/mattermost
    
    local config_file="${NGINX_CONF_DIR}/sites-available/mattermost"
    
    if [ "$NEED_SSL" = "yes" ]; then
        # HTTPS configuration
        cat > "$config_file" <<EOF
upstream mattermost {
    server 127.0.0.1:8065;
    keepalive 32;
}

proxy_cache_path /var/cache/nginx/mattermost levels=1:2 keys_zone=mattermost_cache:10m max_size=3g inactive=120m use_temp_path=off;

server {
    listen 80;
    server_name ${MATTERMOST_DOMAIN};
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${MATTERMOST_DOMAIN};

    ssl_certificate /etc/nginx/ssl/${MATTERMOST_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${MATTERMOST_DOMAIN}/privkey.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    client_max_body_size 50M;

    location ~ /api/v[0-9]+/(users/)?websocket$ {
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        client_max_body_size 50M;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Frame-Options SAMEORIGIN;
        proxy_buffers 256 16k;
        proxy_buffer_size 16k;
        client_body_timeout 60;
        send_timeout 300;
        lingering_timeout 5;
        proxy_connect_timeout 90;
        proxy_send_timeout 300;
        proxy_read_timeout 90s;
        proxy_pass http://mattermost;
    }

    location / {
        client_max_body_size 50M;
        proxy_set_header Connection "";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Frame-Options SAMEORIGIN;
        proxy_buffers 256 16k;
        proxy_buffer_size 16k;
        proxy_read_timeout 600s;
        proxy_cache mattermost_cache;
        proxy_cache_revalidate on;
        proxy_cache_min_uses 2;
        proxy_cache_use_stale timeout;
        proxy_cache_lock on;
        proxy_http_version 1.1;
        proxy_pass http://mattermost;
    }
}
EOF
    else
        # HTTP only configuration
        cat > "$config_file" <<EOF
upstream mattermost {
    server 127.0.0.1:8065;
    keepalive 32;
}

server {
    listen 80;
    server_name ${MATTERMOST_DOMAIN};

    client_max_body_size 50M;

    location ~ /api/v[0-9]+/(users/)?websocket$ {
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        client_max_body_size 50M;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Frame-Options SAMEORIGIN;
        proxy_buffers 256 16k;
        proxy_buffer_size 16k;
        proxy_pass http://mattermost;
    }

    location / {
        proxy_set_header Connection "";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Frame-Options SAMEORIGIN;
        proxy_http_version 1.1;
        proxy_pass http://mattermost;
    }
}
EOF
    fi
    
    # Enable site
    ln -sf "$config_file" "${NGINX_CONF_DIR}/sites-enabled/mattermost"
    
    # Test NGINX configuration
    if nginx -t; then
        print_success "Mattermost NGINX configuration created"
    else
        print_error "NGINX configuration test failed"
        exit 1
    fi
}

configure_nginx_jitsi() {
    if [ "$INSTALL_JITSI" != "yes" ]; then
        return 0
    fi
    
    print_status "Configuring NGINX for Jitsi..."
    
    local config_file="${NGINX_CONF_DIR}/sites-available/jitsi"
    
    if [ "$NEED_SSL" = "yes" ]; then
        cat > "$config_file" <<EOF
server {
    listen 80;
    server_name ${JITSI_DOMAIN};
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${JITSI_DOMAIN};

    ssl_certificate /etc/nginx/ssl/${JITSI_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${JITSI_DOMAIN}/privkey.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers off;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /http-bind {
        proxy_pass http://127.0.0.1:8000/http-bind;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$host;
    }

    location /xmpp-websocket {
        proxy_pass http://127.0.0.1:8000/xmpp-websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        tcp_nodelay on;
    }
}
EOF
    else
        cat > "$config_file" <<EOF
server {
    listen 80;
    server_name ${JITSI_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /http-bind {
        proxy_pass http://127.0.0.1:8000/http-bind;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$host;
    }

    location /xmpp-websocket {
        proxy_pass http://127.0.0.1:8000/xmpp-websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        tcp_nodelay on;
    }
}
EOF
    fi
    
    # Enable site
    ln -sf "$config_file" "${NGINX_CONF_DIR}/sites-enabled/jitsi"
    
    # Test NGINX configuration
    if nginx -t; then
        print_success "Jitsi NGINX configuration created"
    else
        print_error "NGINX configuration test failed"
        exit 1
    fi
}

reload_nginx() {
    print_status "Reloading NGINX..."
    systemctl reload nginx
    print_success "NGINX reloaded"
}

################################################################################
# SSL Certificate Management
################################################################################

setup_ssl_certificates() {
    if [ "$NEED_SSL" != "yes" ]; then
        return 0
    fi
    
    print_status "Setting up SSL certificates..."
    
    case "$SSL_METHOD" in
        letsencrypt)
            setup_letsencrypt
            ;;
        upload)
            setup_uploaded_certs
            ;;
        selfsigned)
            setup_selfsigned_certs
            ;;
        *)
            print_error "Invalid SSL method: $SSL_METHOD"
            exit 1
            ;;
    esac
}

setup_letsencrypt() {
    print_status "Installing Certbot..."
    
    # Install certbot
    retry_command apt-get install -y certbot python3-certbot-nginx
    
    # Get certificate for Mattermost
    print_status "Obtaining Let's Encrypt certificate for ${MATTERMOST_DOMAIN}..."
    mkdir -p /etc/nginx/ssl/${MATTERMOST_DOMAIN}
    
    certbot certonly --webroot -w /var/www/html -d ${MATTERMOST_DOMAIN} --non-interactive --agree-tos --email admin@${MATTERMOST_DOMAIN} || {
        print_error "Failed to obtain certificate for ${MATTERMOST_DOMAIN}"
        print_error "Please ensure the domain points to this server and port 80 is accessible"
        exit 1
    }
    
    # Link certificates
    ln -sf /etc/letsencrypt/live/${MATTERMOST_DOMAIN}/fullchain.pem /etc/nginx/ssl/${MATTERMOST_DOMAIN}/fullchain.pem
    ln -sf /etc/letsencrypt/live/${MATTERMOST_DOMAIN}/privkey.pem /etc/nginx/ssl/${MATTERMOST_DOMAIN}/privkey.pem
    
    print_success "Let's Encrypt certificate obtained for Mattermost"
    
    # Get certificate for Jitsi if needed
    if [ "$INSTALL_JITSI" = "yes" ]; then
        print_status "Obtaining Let's Encrypt certificate for ${JITSI_DOMAIN}..."
        mkdir -p /etc/nginx/ssl/${JITSI_DOMAIN}
        
        certbot certonly --webroot -w /var/www/html -d ${JITSI_DOMAIN} --non-interactive --agree-tos --email admin@${JITSI_DOMAIN} || {
            print_error "Failed to obtain certificate for ${JITSI_DOMAIN}"
            exit 1
        }
        
        ln -sf /etc/letsencrypt/live/${JITSI_DOMAIN}/fullchain.pem /etc/nginx/ssl/${JITSI_DOMAIN}/fullchain.pem
        ln -sf /etc/letsencrypt/live/${JITSI_DOMAIN}/privkey.pem /etc/nginx/ssl/${JITSI_DOMAIN}/privkey.pem
        
        print_success "Let's Encrypt certificate obtained for Jitsi"
    fi
    
    # Setup auto-renewal
    systemctl enable certbot.timer
    systemctl start certbot.timer
    print_success "Certbot auto-renewal enabled"
}

setup_uploaded_certs() {
    print_status "Setting up uploaded certificates..."
    
    echo ""
    print_warning "Certificate Upload Instructions:"
    echo "================================================================"
    echo "You need to upload your SSL certificate files to this server."
    echo ""
    echo "Required files for each domain:"
    echo "  1. Full chain certificate (fullchain.pem or certificate.crt)"
    echo "  2. Private key (privkey.pem or private.key)"
    echo ""
    echo "Accepted formats:"
    echo "  - PEM format (most common) - text files with -----BEGIN CERTIFICATE-----"
    echo "  - CRT format (can be converted to PEM)"
    echo ""
    echo "How to upload:"
    echo "  Option 1: Use SCP/SFTP to upload files to /tmp/"
    echo "    Example: scp fullchain.pem root@server:/tmp/"
    echo ""
    echo "  Option 2: Use WinSCP, FileZilla, or similar tools"
    echo "    Upload to: /tmp/ directory"
    echo ""
    echo "  Option 3: Copy-paste certificate content"
    echo "    We'll create the files for you (shown below)"
    echo ""
    echo "================================================================"
    echo ""
    
    # Mattermost certificates
    mkdir -p /etc/nginx/ssl/${MATTERMOST_DOMAIN}
    
    echo "MATTERMOST DOMAIN: ${MATTERMOST_DOMAIN}"
    echo "----------------------------------------"
    echo ""
    echo "Choose upload method:"
    echo "  1) I've already uploaded files to /tmp/"
    echo "  2) I want to paste certificate content now"
    echo ""
    read -p "Enter choice (1 or 2): " upload_method
    
    if [ "$upload_method" = "1" ]; then
        # User uploaded files
        echo ""
        echo "Files in /tmp/:"
        ls -lh /tmp/*.pem /tmp/*.crt /tmp/*.key 2>/dev/null || echo "  (No certificate files found)"
        echo ""
        read -p "Full chain certificate path (e.g., /tmp/fullchain.pem): " mm_cert
        read -p "Private key path (e.g., /tmp/privkey.pem): " mm_key
        
        if [ ! -f "$mm_cert" ] || [ ! -f "$mm_key" ]; then
            print_error "Certificate files not found at specified paths"
            print_error "Please upload files first and run the script again"
            exit 1
        fi
        
        cp "$mm_cert" /etc/nginx/ssl/${MATTERMOST_DOMAIN}/fullchain.pem
        cp "$mm_key" /etc/nginx/ssl/${MATTERMOST_DOMAIN}/privkey.pem
        
    elif [ "$upload_method" = "2" ]; then
        # Paste content
        echo ""
        print_status "Paste your FULL CHAIN CERTIFICATE (including -----BEGIN CERTIFICATE----- and -----END CERTIFICATE-----)"
        echo "Press Ctrl+D when finished:"
        cat > /etc/nginx/ssl/${MATTERMOST_DOMAIN}/fullchain.pem
        
        echo ""
        print_status "Paste your PRIVATE KEY (including -----BEGIN PRIVATE KEY----- and -----END PRIVATE KEY-----)"
        echo "Press Ctrl+D when finished:"
        cat > /etc/nginx/ssl/${MATTERMOST_DOMAIN}/privkey.pem
        
    else
        print_error "Invalid choice"
        exit 1
    fi
    
    chmod 600 /etc/nginx/ssl/${MATTERMOST_DOMAIN}/privkey.pem
    chmod 644 /etc/nginx/ssl/${MATTERMOST_DOMAIN}/fullchain.pem
    
    # Verify certificate
    if openssl x509 -in /etc/nginx/ssl/${MATTERMOST_DOMAIN}/fullchain.pem -noout -text >/dev/null 2>&1; then
        print_success "Mattermost certificate validated"
        # Show certificate details
        echo ""
        print_status "Certificate details:"
        openssl x509 -in /etc/nginx/ssl/${MATTERMOST_DOMAIN}/fullchain.pem -noout -subject -dates
    else
        print_error "Invalid certificate file format"
        print_error "Please ensure you're using PEM format certificates"
        exit 1
    fi
    
    # Verify private key
    if openssl rsa -in /etc/nginx/ssl/${MATTERMOST_DOMAIN}/privkey.pem -check -noout >/dev/null 2>&1 || \
       openssl ec -in /etc/nginx/ssl/${MATTERMOST_DOMAIN}/privkey.pem -check -noout >/dev/null 2>&1; then
        print_success "Private key validated"
    else
        print_error "Invalid private key format"
        exit 1
    fi
    
    # Jitsi certificates
    if [ "$INSTALL_JITSI" = "yes" ]; then
        echo ""
        echo "JITSI DOMAIN: ${JITSI_DOMAIN}"
        echo "----------------------------------------"
        echo ""
        
        mkdir -p /etc/nginx/ssl/${JITSI_DOMAIN}
        
        echo "Choose upload method:"
        echo "  1) I've already uploaded files to /tmp/"
        echo "  2) I want to paste certificate content now"
        echo ""
        read -p "Enter choice (1 or 2): " upload_method_jitsi
        
        if [ "$upload_method_jitsi" = "1" ]; then
            echo ""
            echo "Files in /tmp/:"
            ls -lh /tmp/*.pem /tmp/*.crt /tmp/*.key 2>/dev/null || echo "  (No certificate files found)"
            echo ""
            read -p "Full chain certificate path: " jitsi_cert
            read -p "Private key path: " jitsi_key
            
            if [ ! -f "$jitsi_cert" ] || [ ! -f "$jitsi_key" ]; then
                print_error "Certificate files not found"
                exit 1
            fi
            
            cp "$jitsi_cert" /etc/nginx/ssl/${JITSI_DOMAIN}/fullchain.pem
            cp "$jitsi_key" /etc/nginx/ssl/${JITSI_DOMAIN}/privkey.pem
            
        elif [ "$upload_method_jitsi" = "2" ]; then
            echo ""
            print_status "Paste your FULL CHAIN CERTIFICATE for Jitsi"
            echo "Press Ctrl+D when finished:"
            cat > /etc/nginx/ssl/${JITSI_DOMAIN}/fullchain.pem
            
            echo ""
            print_status "Paste your PRIVATE KEY for Jitsi"
            echo "Press Ctrl+D when finished:"
            cat > /etc/nginx/ssl/${JITSI_DOMAIN}/privkey.pem
            
        else
            print_error "Invalid choice"
            exit 1
        fi
        
        chmod 600 /etc/nginx/ssl/${JITSI_DOMAIN}/privkey.pem
        chmod 644 /etc/nginx/ssl/${JITSI_DOMAIN}/fullchain.pem
        
        if openssl x509 -in /etc/nginx/ssl/${JITSI_DOMAIN}/fullchain.pem -noout -text >/dev/null 2>&1; then
            print_success "Jitsi certificate validated"
            echo ""
            print_status "Certificate details:"
            openssl x509 -in /etc/nginx/ssl/${JITSI_DOMAIN}/fullchain.pem -noout -subject -dates
        else
            print_error "Invalid certificate file"
            exit 1
        fi
        
        if openssl rsa -in /etc/nginx/ssl/${JITSI_DOMAIN}/privkey.pem -check -noout >/dev/null 2>&1 || \
           openssl ec -in /etc/nginx/ssl/${JITSI_DOMAIN}/privkey.pem -check -noout >/dev/null 2>&1; then
            print_success "Private key validated"
        else
            print_error "Invalid private key format"
            exit 1
        fi
    fi
    
    # Clean up temporary files if user uploaded to /tmp
    if [ "$upload_method" = "1" ]; then
        print_status "Cleaning up temporary certificate files from /tmp..."
        read -p "Remove uploaded files from /tmp? (yes/no): " cleanup
        if [ "$cleanup" = "yes" ]; then
            rm -f "$mm_cert" "$mm_key" 2>/dev/null
            if [ "$INSTALL_JITSI" = "yes" ] && [ "$upload_method_jitsi" = "1" ]; then
                rm -f "$jitsi_cert" "$jitsi_key" 2>/dev/null
            fi
            print_success "Temporary files cleaned up"
        fi
    fi
}

setup_selfsigned_certs() {
    print_status "Generating self-signed certificates..."
    
    print_warning "Self-signed certificates will trigger browser warnings"
    
    # Mattermost certificate
    mkdir -p /etc/nginx/ssl/${MATTERMOST_DOMAIN}
    
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/${MATTERMOST_DOMAIN}/privkey.pem \
        -out /etc/nginx/ssl/${MATTERMOST_DOMAIN}/fullchain.pem \
        -subj "/C=IR/ST=Tehran/L=Tehran/O=Mattermost/CN=${MATTERMOST_DOMAIN}"
    
    chmod 600 /etc/nginx/ssl/${MATTERMOST_DOMAIN}/privkey.pem
    print_success "Self-signed certificate generated for Mattermost"
    
    # Jitsi certificate
    if [ "$INSTALL_JITSI" = "yes" ]; then
        mkdir -p /etc/nginx/ssl/${JITSI_DOMAIN}
        
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout /etc/nginx/ssl/${JITSI_DOMAIN}/privkey.pem \
            -out /etc/nginx/ssl/${JITSI_DOMAIN}/fullchain.pem \
            -subj "/C=IR/ST=Tehran/L=Tehran/O=Jitsi/CN=${JITSI_DOMAIN}"
        
        chmod 600 /etc/nginx/ssl/${JITSI_DOMAIN}/privkey.pem
        print_success "Self-signed certificate generated for Jitsi"
    fi
}

################################################################################
# Mattermost Installation
################################################################################

create_mattermost_compose() {
    print_status "Creating Mattermost Docker Compose file..."
    
    mkdir -p ${INSTALL_DIR}/mattermost
    
    cat > ${INSTALL_DIR}/mattermost/docker-compose.yml <<EOF
version: '3.3'

services:
  postgres:
    image: postgres:14-alpine
    restart: unless-stopped
    container_name: mattermost-postgres
    security_opt:
      - no-new-privileges:true
    pids_limit: 100
    read_only: true
    tmpfs:
      - /tmp
      - /var/run/postgresql
    volumes:
      - ./volumes/db/var/lib/postgresql/data:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=${MATTERMOST_DB_USER}
      - POSTGRES_PASSWORD=${DB_PASSWORD}
      - POSTGRES_DB=${MATTERMOST_DB_NAME}
      - POSTGRES_HOST_AUTH_METHOD=scram-sha-256
      - POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256
    networks:
      - mattermost-network

  mattermost:
    image: mattermost/mattermost-team-edition:latest
    restart: unless-stopped
    container_name: mattermost-app
    security_opt:
      - no-new-privileges:true
    pids_limit: 200
    read_only: false
    tmpfs:
      - /tmp
    volumes:
      - ./volumes/app/mattermost/config:/mattermost/config:rw
      - ./volumes/app/mattermost/data:/mattermost/data:rw
      - ./volumes/app/mattermost/logs:/mattermost/logs:rw
      - ./volumes/app/mattermost/plugins:/mattermost/plugins:rw
      - ./volumes/app/mattermost/client/plugins:/mattermost/client/plugins:rw
      - ./volumes/app/mattermost/bleve-indexes:/mattermost/bleve-indexes:rw
    environment:
      - TZ=UTC
      - MM_SQLSETTINGS_DRIVERNAME=postgres
      - MM_SQLSETTINGS_DATASOURCE=postgres://${MATTERMOST_DB_USER}:${DB_PASSWORD}@postgres:5432/${MATTERMOST_DB_NAME}?sslmode=disable&connect_timeout=10
      - MM_BLEVESETTINGS_INDEXDIR=/mattermost/bleve-indexes
      - MM_SERVICESETTINGS_SITEURL=https://${MATTERMOST_DOMAIN}
    ports:
      - "127.0.0.1:8065:8065"
    depends_on:
      - postgres
    networks:
      - mattermost-network

networks:
  mattermost-network:
    driver: bridge
EOF
    
    print_success "Mattermost Docker Compose file created"
}

start_mattermost() {
    print_status "Starting Mattermost containers..."
    
    cd ${INSTALL_DIR}/mattermost
    
    # Create necessary directories
    mkdir -p volumes/db/var/lib/postgresql/data
    mkdir -p volumes/app/mattermost/{config,data,logs,plugins,client/plugins,bleve-indexes}
    
    # Set proper permissions
    chmod -R 2777 volumes/
    
    # Try docker compose first, then docker-compose
    if docker compose version >/dev/null 2>&1; then
        retry_command docker compose up -d
    elif command_exists docker-compose; then
        retry_command docker-compose up -d
    else
        print_error "Neither 'docker compose' nor 'docker-compose' is available"
        exit 1
    fi
    
    print_success "Mattermost containers started"
    
    # Wait for Mattermost to be ready
    print_status "Waiting for Mattermost to be ready (this may take 30-60 seconds)..."
    local max_wait=120
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if curl -sf http://localhost:8065 >/dev/null 2>&1; then
            print_success "Mattermost is ready!"
            break
        fi
        sleep 5
        waited=$((waited + 5))
        echo -n "."
    done
    echo ""
    
    if [ $waited -ge $max_wait ]; then
        print_warning "Mattermost took longer than expected to start. Check logs with: docker logs mattermost-app"
    fi
}

################################################################################
# Jitsi Installation
################################################################################

create_jitsi_env() {
    if [ "$INSTALL_JITSI" != "yes" ]; then
        return 0
    fi
    
    print_status "Creating Jitsi environment file..."
    
    mkdir -p ${INSTALL_DIR}/jitsi
    
    cat > ${INSTALL_DIR}/jitsi/.env <<EOF
# Jitsi Meet Configuration
# Generated by installation script

# Image version
JITSI_IMAGE_VERSION=stable-9258

# Container restart policy
RESTART_POLICY=unless-stopped

# System time zone
TZ=UTC

# Public URL for Jitsi Meet
PUBLIC_URL=https://${JITSI_DOMAIN}

# IP address of the Docker host
DOCKER_HOST_ADDRESS=$(hostname -I | awk '{print $1}')

# XMPP configuration
XMPP_DOMAIN=meet.jitsi
XMPP_AUTH_DOMAIN=auth.meet.jitsi
XMPP_BOSH_URL_BASE=http://prosody:5280
XMPP_GUEST_DOMAIN=guest.meet.jitsi
XMPP_MUC_DOMAIN=muc.meet.jitsi
XMPP_INTERNAL_MUC_DOMAIN=internal-muc.meet.jitsi
XMPP_MODULES=
XMPP_MUC_MODULES=
XMPP_INTERNAL_MUC_MODULES=
XMPP_RECORDER_DOMAIN=recorder.meet.jitsi
XMPP_PORT=5222
XMPP_SERVER=prosody

# XMPP component password for Jicofo
JICOFO_COMPONENT_SECRET=${JICOFO_COMPONENT_SECRET}
JICOFO_AUTH_PASSWORD=${JICOFO_AUTH_PASSWORD}

# XMPP user credentials for JVB
JVB_AUTH_USER=jvb
JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}
JVB_BREWERY_MUC=jvbbrewery
JVB_PORT=10000
JVB_STUN_SERVERS=meet-jit-si-turnrelay.jitsi.net:443

# XMPP user credentials for Jibri
JIBRI_RECORDER_USER=recorder
JIBRI_RECORDER_PASSWORD=${JIBRI_RECORDER_PASSWORD}
JIBRI_XMPP_USER=jibri
JIBRI_XMPP_PASSWORD=${JIBRI_XMPP_PASSWORD}

# Disable HTTPS (handled by NGINX)
DISABLE_HTTPS=1
ENABLE_HTTP_REDIRECT=0

# HTTP port
HTTP_PORT=8000
HTTPS_PORT=8443

# Enable authentication (set to 1 to enable)
ENABLE_AUTH=0
ENABLE_GUESTS=1

# Enable recording
ENABLE_RECORDING=0

# Enable transcriptions
ENABLE_TRANSCRIPTIONS=0

# Enable breakout rooms
ENABLE_BREAKOUT_ROOMS=1

# Enable lobby
ENABLE_LOBBY=1

# Enable E2E encryption
ENABLE_E2EPING=0

# Configuration directory
CONFIG=./config

# Prosody configuration
PROSODY_HTTP_PORT=5280
PROSODY_S2S_PORT=5269

# Jicofo configuration
JICOFO_REST_PORT=8888

# JVB configuration
JVB_COLIBRI_PORT=8080

# Additional settings
ENABLE_XMPP_WEBSOCKET=1
ENABLE_COLIBRI_WEBSOCKET=1
ENABLE_OCTO=0
ENABLE_SCTP=1
EOF
    
    print_success "Jitsi environment file created"
}

create_jitsi_compose() {
    if [ "$INSTALL_JITSI" != "yes" ]; then
        return 0
    fi
    
    print_status "Creating Jitsi Docker Compose file..."
    
    cat > ${INSTALL_DIR}/jitsi/docker-compose.yml <<'EOF'
version: '3.3'

services:
  web:
    image: jitsi/web:${JITSI_IMAGE_VERSION:-stable-9258}
    restart: ${RESTART_POLICY:-unless-stopped}
    container_name: jitsi-web
    ports:
      - '127.0.0.1:8000:80'
    volumes:
      - ${CONFIG}/web:/config:Z
      - ${CONFIG}/web/crontabs:/var/spool/cron/crontabs:Z
      - ${CONFIG}/transcripts:/usr/share/jitsi-meet/transcripts:Z
    environment:
      - AMPLITUDE_ID
      - ANALYTICS_SCRIPT_URLS
      - DISABLE_HTTPS
      - ENABLE_AUTH
      - ENABLE_GUESTS
      - ENABLE_HTTP_REDIRECT
      - ENABLE_HSTS
      - ENABLE_XMPP_WEBSOCKET
      - ENABLE_COLIBRI_WEBSOCKET
      - ENABLE_BREAKOUT_ROOMS
      - ENABLE_LOBBY
      - ENABLE_RECORDING
      - ENABLE_TRANSCRIPTIONS
      - ENABLE_E2EPING
      - PUBLIC_URL
      - TZ
      - XMPP_AUTH_DOMAIN
      - XMPP_BOSH_URL_BASE
      - XMPP_DOMAIN
      - XMPP_GUEST_DOMAIN
      - XMPP_MUC_DOMAIN
      - XMPP_RECORDER_DOMAIN
      - XMPP_PORT
    networks:
      meet.jitsi:
    depends_on:
      - prosody

  prosody:
    image: jitsi/prosody:${JITSI_IMAGE_VERSION:-stable-9258}
    restart: ${RESTART_POLICY:-unless-stopped}
    container_name: jitsi-prosody
    expose:
      - '5222'
      - '5347'
      - '5280'
    volumes:
      - ${CONFIG}/prosody/config:/config:Z
      - ${CONFIG}/prosody/prosody-plugins-custom:/prosody-plugins-custom:Z
    environment:
      - AUTH_TYPE
      - ENABLE_AUTH
      - ENABLE_GUESTS
      - ENABLE_LOBBY
      - ENABLE_XMPP_WEBSOCKET
      - GLOBAL_MODULES
      - JIBRI_RECORDER_USER
      - JIBRI_RECORDER_PASSWORD
      - JIBRI_XMPP_USER
      - JIBRI_XMPP_PASSWORD
      - JICOFO_AUTH_PASSWORD
      - JICOFO_COMPONENT_SECRET
      - JVB_AUTH_USER
      - JVB_AUTH_PASSWORD
      - PUBLIC_URL
      - TZ
      - XMPP_DOMAIN
      - XMPP_AUTH_DOMAIN
      - XMPP_GUEST_DOMAIN
      - XMPP_MUC_DOMAIN
      - XMPP_INTERNAL_MUC_DOMAIN
      - XMPP_MODULES
      - XMPP_MUC_MODULES
      - XMPP_INTERNAL_MUC_MODULES
      - XMPP_RECORDER_DOMAIN
      - XMPP_PORT
    networks:
      meet.jitsi:
        aliases:
          - ${XMPP_SERVER:-xmpp.meet.jitsi}

  jicofo:
    image: jitsi/jicofo:${JITSI_IMAGE_VERSION:-stable-9258}
    restart: ${RESTART_POLICY:-unless-stopped}
    container_name: jitsi-jicofo
    ports:
      - '127.0.0.1:8888:8888'
    volumes:
      - ${CONFIG}/jicofo:/config:Z
    environment:
      - AUTH_TYPE
      - ENABLE_AUTH
      - JICOFO_AUTH_PASSWORD
      - JVB_BREWERY_MUC
      - JIBRI_BREWERY_MUC
      - JIBRI_PENDING_TIMEOUT
      - TZ
      - XMPP_DOMAIN
      - XMPP_AUTH_DOMAIN
      - XMPP_INTERNAL_MUC_DOMAIN
      - XMPP_MUC_DOMAIN
      - XMPP_SERVER
      - XMPP_PORT
      - XMPP_RECORDER_DOMAIN
    depends_on:
      - prosody
    networks:
      meet.jitsi:

  jvb:
    image: jitsi/jvb:${JITSI_IMAGE_VERSION:-stable-9258}
    restart: ${RESTART_POLICY:-unless-stopped}
    container_name: jitsi-jvb
    ports:
      - '${JVB_PORT:-10000}:${JVB_PORT:-10000}/udp'
      - '127.0.0.1:8080:8080'
    volumes:
      - ${CONFIG}/jvb:/config:Z
    environment:
      - DOCKER_HOST_ADDRESS
      - ENABLE_COLIBRI_WEBSOCKET
      - ENABLE_OCTO
      - ENABLE_SCTP
      - JVB_AUTH_USER
      - JVB_AUTH_PASSWORD
      - JVB_BREWERY_MUC
      - JVB_PORT
      - JVB_STUN_SERVERS
      - PUBLIC_URL
      - TZ
      - XMPP_AUTH_DOMAIN
      - XMPP_INTERNAL_MUC_DOMAIN
      - XMPP_SERVER
      - XMPP_PORT
    depends_on:
      - prosody
    networks:
      meet.jitsi:

networks:
  meet.jitsi:
    driver: bridge
EOF
    
    print_success "Jitsi Docker Compose file created"
}

start_jitsi() {
    if [ "$INSTALL_JITSI" != "yes" ]; then
        return 0
    fi
    
    print_status "Starting Jitsi containers..."
    
    cd ${INSTALL_DIR}/jitsi
    
    # Create config directories
    mkdir -p config/{web,prosody,jicofo,jvb}
    
    # Try docker compose first, then docker-compose
    if docker compose version >/dev/null 2>&1; then
        retry_command docker compose up -d
    elif command_exists docker-compose; then
        retry_command docker-compose up -d
    else
        print_error "Neither 'docker compose' nor 'docker-compose' is available"
        exit 1
    fi
    
    print_success "Jitsi containers started"
    
    # Wait for Jitsi to be ready
    print_status "Waiting for Jitsi to be ready (this may take 30-60 seconds)..."
    local max_wait=120
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if curl -sf http://localhost:8000 >/dev/null 2>&1; then
            print_success "Jitsi is ready!"
            break
        fi
        sleep 5
        waited=$((waited + 5))
        echo -n "."
    done
    echo ""
    
    if [ $waited -ge $max_wait ]; then
        print_warning "Jitsi took longer than expected to start. Check logs with: docker logs jitsi-web"
    fi
}

################################################################################
# User Input Collection
################################################################################

collect_user_input() {
    print_status "Collecting configuration information..."
    echo ""
    
    # Ask about Jitsi installation
    while true; do
        read -p "Do you want to install Jitsi Meet for video conferencing? (yes/no): " INSTALL_JITSI
        case $INSTALL_JITSI in
            yes|no) break ;;
            *) print_error "Please answer 'yes' or 'no'" ;;
        esac
    done
    
    if [ "$INSTALL_JITSI" = "yes" ]; then
        print_warning "Jitsi requirements:"
        echo "  - UDP port 10000 must be open and accessible from the internet"
        echo "  - 8GB+ RAM recommended for smooth video conferencing"
        echo "  - Domain must point to this server's public IP"
        echo ""
    fi
    
    # Mattermost domain
    while true; do
        read -p "Enter Mattermost domain (e.g., mattermost.example.com): " MATTERMOST_DOMAIN
        if validate_domain "$MATTERMOST_DOMAIN"; then
            break
        else
            print_error "Invalid domain format. Please try again."
        fi
    done
    
    # Jitsi domain
    if [ "$INSTALL_JITSI" = "yes" ]; then
        while true; do
            read -p "Enter Jitsi domain (e.g., jitsi.example.com): " JITSI_DOMAIN
            if validate_domain "$JITSI_DOMAIN"; then
                break
            else
                print_error "Invalid domain format. Please try again."
            fi
        done
    fi
    
    # Check DNS
    print_status "Checking DNS resolution..."
    check_dns "$MATTERMOST_DOMAIN"
    if [ "$INSTALL_JITSI" = "yes" ]; then
        check_dns "$JITSI_DOMAIN"
    fi
    
    # SSL configuration
    while true; do
        read -p "Do you need SSL/TLS certificates? (yes/no): " NEED_SSL
        case $NEED_SSL in
            yes|no) break ;;
            *) print_error "Please answer 'yes' or 'no'" ;;
        esac
    done
    
    if [ "$NEED_SSL" = "yes" ]; then
        print_warning "IMPORTANT: For Let's Encrypt to work:"
        echo "  - Your domains must point to this server's public IP address"
        echo "  - Ports 80 and 443 must be accessible from the internet"
        echo "  - No other web server should be running on these ports"
        echo ""
        
        echo "SSL Certificate Options:"
        echo "  1) letsencrypt - Free automated certificates from Let's Encrypt"
        echo "  2) upload - Use your own certificates"
        echo "  3) selfsigned - Generate self-signed certificates (browsers will show warnings)"
        echo ""
        
        while true; do
            read -p "Choose SSL method (letsencrypt/upload/selfsigned): " SSL_METHOD
            case $SSL_METHOD in
                letsencrypt|upload|selfsigned) break ;;
                *) print_error "Please choose: letsencrypt, upload, or selfsigned" ;;
            esac
        done
    fi
    
    # Mattermost admin credentials
    print_status "Mattermost Admin Account Setup"
    
    read -p "Enter Mattermost admin email: " MATTERMOST_ADMIN_EMAIL
    read -p "Enter Mattermost admin username: " MATTERMOST_ADMIN_USERNAME
    
    while true; do
        read -sp "Enter Mattermost admin password (leave empty to auto-generate): " MATTERMOST_ADMIN_PASSWORD
        echo ""
        if [ -z "$MATTERMOST_ADMIN_PASSWORD" ]; then
            MATTERMOST_ADMIN_PASSWORD=$(generate_password 20)
            print_success "Auto-generated admin password"
            break
        elif [ ${#MATTERMOST_ADMIN_PASSWORD} -lt 8 ]; then
            print_error "Password must be at least 8 characters"
        else
            break
        fi
    done
    
    # Database passwords
    print_status "Generating secure database passwords..."
    DB_PASSWORD=$(generate_password 32)
    POSTGRES_PASSWORD=$(generate_password 32)
    
    # Jitsi passwords
    if [ "$INSTALL_JITSI" = "yes" ]; then
        print_status "Generating secure Jitsi passwords..."
        JICOFO_AUTH_PASSWORD=$(generate_password 32)
        JICOFO_COMPONENT_SECRET=$(generate_password 32)
        JVB_AUTH_PASSWORD=$(generate_password 32)
        JIBRI_RECORDER_PASSWORD=$(generate_password 32)
        JIBRI_XMPP_PASSWORD=$(generate_password 32)
    fi
    
    print_success "Configuration collection completed"
    echo ""
}

################################################################################
# Save Credentials
################################################################################

save_credentials() {
    print_status "Saving credentials to ${CREDENTIALS_FILE}..."
    
    cat > "$CREDENTIALS_FILE" <<EOF
================================================================================
MATTERMOST & JITSI INSTALLATION CREDENTIALS
Generated: $(date)
================================================================================

MATTERMOST INFORMATION
----------------------
Domain: https://${MATTERMOST_DOMAIN}
Admin Email: ${MATTERMOST_ADMIN_EMAIL}
Admin Username: ${MATTERMOST_ADMIN_USERNAME}
Admin Password: ${MATTERMOST_ADMIN_PASSWORD}

Database User: ${MATTERMOST_DB_USER}
Database Name: ${MATTERMOST_DB_NAME}
Database Password: ${DB_PASSWORD}

EOF
    
    if [ "$INSTALL_JITSI" = "yes" ]; then
        cat >> "$CREDENTIALS_FILE" <<EOF
JITSI INFORMATION
-----------------
Domain: https://${JITSI_DOMAIN}

Jitsi Internal Passwords (for reference only):
- JICOFO_AUTH_PASSWORD: ${JICOFO_AUTH_PASSWORD}
- JICOFO_COMPONENT_SECRET: ${JICOFO_COMPONENT_SECRET}
- JVB_AUTH_PASSWORD: ${JVB_AUTH_PASSWORD}
- JIBRI_RECORDER_PASSWORD: ${JIBRI_RECORDER_PASSWORD}
- JIBRI_XMPP_PASSWORD: ${JIBRI_XMPP_PASSWORD}

EOF
    fi
    
    cat >> "$CREDENTIALS_FILE" <<EOF
INSTALLATION DETAILS
--------------------
Installation Directory: ${INSTALL_DIR}
SSL Method: ${SSL_METHOD:-none}
Nginx Configuration: ${NGINX_CONF_DIR}/sites-available/
Log File: ${LOG_FILE}

IMPORTANT SECURITY NOTES
------------------------
1. This file contains sensitive credentials - keep it secure!
2. File permissions have been set to 600 (root only)
3. Consider moving this file to a secure location after review
4. All passwords are strong auto-generated passwords
5. Database passwords are stored in Docker environment files

DOCKER COMMANDS
---------------
Mattermost:
  - View logs: docker logs mattermost-app
  - Restart: cd ${INSTALL_DIR}/mattermost && docker compose restart
  - Stop: cd ${INSTALL_DIR}/mattermost && docker compose stop
  - Start: cd ${INSTALL_DIR}/mattermost && docker compose start

EOF
    
    if [ "$INSTALL_JITSI" = "yes" ]; then
        cat >> "$CREDENTIALS_FILE" <<EOF
Jitsi:
  - View logs: docker logs jitsi-web
  - Restart: cd ${INSTALL_DIR}/jitsi && docker compose restart
  - Stop: cd ${INSTALL_DIR}/jitsi && docker compose stop
  - Start: cd ${INSTALL_DIR}/jitsi && docker compose start

EOF
    fi
    
    cat >> "$CREDENTIALS_FILE" <<EOF
FIREWALL PORTS
--------------
- 22/tcp - SSH
- 80/tcp - HTTP
- 443/tcp - HTTPS
EOF
    
    if [ "$INSTALL_JITSI" = "yes" ]; then
        echo "- 10000/udp - Jitsi Video Bridge" >> "$CREDENTIALS_FILE"
    fi
    
    cat >> "$CREDENTIALS_FILE" <<EOF

NEXT STEPS
----------
1. Access Mattermost at https://${MATTERMOST_DOMAIN}
2. Complete initial setup wizard with admin credentials above
EOF
    
    if [ "$INSTALL_JITSI" = "yes" ]; then
        cat >> "$CREDENTIALS_FILE" <<EOF
3. Access Jitsi at https://${JITSI_DOMAIN}
4. Create your first video conference room
EOF
    fi
    
    cat >> "$CREDENTIALS_FILE" <<EOF

BACKUP RECOMMENDATIONS
----------------------
- Backup ${INSTALL_DIR}/mattermost/volumes regularly
EOF
    
    if [ "$INSTALL_JITSI" = "yes" ]; then
        echo "- Backup ${INSTALL_DIR}/jitsi/config regularly" >> "$CREDENTIALS_FILE"
    fi
    
    cat >> "$CREDENTIALS_FILE" <<EOF
- Keep database backups in a secure location
- Store this credentials file securely

SSL CERTIFICATE INFORMATION
----------------------------
EOF
    
    if [ "$SSL_METHOD" = "upload" ]; then
        cat >> "$CREDENTIALS_FILE" <<EOF
Your SSL certificates are stored at:
- Mattermost: /etc/nginx/ssl/${MATTERMOST_DOMAIN}/
EOF
        if [ "$INSTALL_JITSI" = "yes" ]; then
            echo "- Jitsi: /etc/nginx/ssl/${JITSI_DOMAIN}/" >> "$CREDENTIALS_FILE"
        fi
        cat >> "$CREDENTIALS_FILE" <<EOF

Certificate files:
- fullchain.pem (full certificate chain)
- privkey.pem (private key - keep secure!)

To renew certificates:
1. Upload new certificate files to /tmp/
2. Run: cp /tmp/fullchain.pem /etc/nginx/ssl/${MATTERMOST_DOMAIN}/
3. Run: cp /tmp/privkey.pem /etc/nginx/ssl/${MATTERMOST_DOMAIN}/
4. Run: chmod 600 /etc/nginx/ssl/${MATTERMOST_DOMAIN}/privkey.pem
5. Run: systemctl reload nginx
EOF
    elif [ "$SSL_METHOD" = "letsencrypt" ]; then
        cat >> "$CREDENTIALS_FILE" <<EOF
Let's Encrypt certificates auto-renew via certbot.timer
Certificate location: /etc/letsencrypt/live/

To manually renew:
  certbot renew

To check renewal timer:
  systemctl status certbot.timer
EOF
    elif [ "$SSL_METHOD" = "selfsigned" ]; then
        cat >> "$CREDENTIALS_FILE" <<EOF
Self-signed certificates are valid for 365 days.
Location: /etc/nginx/ssl/

To regenerate (when expired):
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \\
    -keyout /etc/nginx/ssl/${MATTERMOST_DOMAIN}/privkey.pem \\
    -out /etc/nginx/ssl/${MATTERMOST_DOMAIN}/fullchain.pem \\
    -subj "/C=IR/ST=Tehran/L=Tehran/O=Mattermost/CN=${MATTERMOST_DOMAIN}"
  systemctl reload nginx
EOF
    fi
    
    cat >> "$CREDENTIALS_FILE" <<EOF

ADDITIONAL FEATURES TO CONSIDER
--------------------------------
- Email/SMTP configuration for Mattermost notifications
- OAuth/SAML authentication for single sign-on
- Automatic backups with cron jobs
- Monitoring with Prometheus/Grafana
- Fail2ban for additional security
- Regular security updates

For support and documentation:
- Mattermost: https://docs.mattermost.com
- Jitsi: https://jitsi.github.io/handbook/

================================================================================
EOF
    
    chmod 600 "$CREDENTIALS_FILE"
    print_success "Credentials saved to ${CREDENTIALS_FILE}"
}

################################################################################
# Display Summary
################################################################################

display_summary() {
    echo ""
    echo "================================================================================"
    print_success "INSTALLATION COMPLETED SUCCESSFULLY!"
    echo "================================================================================"
    echo ""
    
    print_status "Access Information:"
    echo ""
    echo "  Mattermost:"
    if [ "$NEED_SSL" = "yes" ]; then
        echo "    URL: https://${MATTERMOST_DOMAIN}"
    else
        echo "    URL: http://${MATTERMOST_DOMAIN}"
    fi
    echo "    Admin Email: ${MATTERMOST_ADMIN_EMAIL}"
    echo "    Admin Username: ${MATTERMOST_ADMIN_USERNAME}"
    echo "    Admin Password: ${MATTERMOST_ADMIN_PASSWORD}"
    echo ""
    
    if [ "$INSTALL_JITSI" = "yes" ]; then
        echo "  Jitsi Meet:"
        if [ "$NEED_SSL" = "yes" ]; then
            echo "    URL: https://${JITSI_DOMAIN}"
        else
            echo "    URL: http://${JITSI_DOMAIN}"
        fi
        echo "    (No login required - create rooms directly)"
        echo ""
    fi
    
    print_status "Important Files:"
    echo "    Credentials: ${CREDENTIALS_FILE}"
    echo "    Installation: ${INSTALL_DIR}"
    echo "    Logs: ${LOG_FILE}"
    echo ""
    
    print_warning "Security Reminders:"
    echo "  1. Credentials file is stored at: ${CREDENTIALS_FILE}"
    echo "  2. All passwords are automatically generated and secure"
    echo "  3. Keep the credentials file in a secure location"
    echo "  4. Regular security updates are recommended"
    echo "  5. Consider enabling Fail2ban for additional security"
    echo ""
    
    if [ "$SSL_METHOD" = "selfsigned" ]; then
        print_warning "SSL Certificate Warning:"
        echo "  - You are using self-signed certificates"
        echo "  - Browsers will show security warnings"
        echo "  - Consider using Let's Encrypt for production use"
        echo ""
    fi
    
    print_status "Useful Docker Commands:"
    echo "  View Mattermost logs: docker logs -f mattermost-app"
    if [ "$INSTALL_JITSI" = "yes" ]; then
        echo "  View Jitsi logs: docker logs -f jitsi-web"
    fi
    echo "  View all containers: docker ps -a"
    echo ""
    
    print_status "Next Steps:"
    echo "  1. Access Mattermost and complete the setup wizard"
    if [ "$INSTALL_JITSI" = "yes" ]; then
        echo "  2. Test Jitsi by creating a video conference room"
        echo "  3. Configure Mattermost to use Jitsi for video calls (optional)"
    fi
    echo ""
    
    echo "================================================================================"
    print_success "Thank you for using the installation script!"
    echo "================================================================================"
    echo ""
}

################################################################################
# Main Installation Flow
################################################################################

main() {
    clear
    echo "================================================================================"
    echo "          Mattermost + Jitsi Installation Script"
    echo "          Ubuntu 20.04 / 22.04 / 24.04 LTS"
    echo "          With Iranian Mirror Support"
    echo "================================================================================"
    echo ""
    
    # Initialize log file
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    
    print_status "Starting installation at $(date)" | tee -a "$LOG_FILE"
    echo ""
    
    # System checks
    check_system_requirements
    
    # Collect user input
    collect_user_input
    
    # Confirm installation
    echo ""
    print_warning "Ready to begin installation with the following configuration:"
    echo "  - Mattermost domain: ${MATTERMOST_DOMAIN}"
    if [ "$INSTALL_JITSI" = "yes" ]; then
        echo "  - Jitsi domain: ${JITSI_DOMAIN}"
    fi
    echo "  - SSL: ${NEED_SSL} ${SSL_METHOD:+(Method: $SSL_METHOD)}"
    echo ""
    read -p "Continue with installation? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        print_error "Installation cancelled by user"
        exit 0
    fi
    
    # Start installation
    configure_dns
    configure_repositories
    
    # Install packages
    print_status "Installing required packages..."
    retry_command apt-get install -y curl wget git openssl
    
    # Install Docker
    install_docker
    install_docker_compose
    configure_docker_daemon
    
    # Install NGINX
    install_nginx
    
    # Configure firewall
    configure_firewall
    
    # Setup SSL certificates (if needed, before final NGINX config)
    if [ "$NEED_SSL" = "yes" ]; then
        if [ "$SSL_METHOD" = "letsencrypt" ]; then
            # Create temporary HTTP-only NGINX config for Let's Encrypt verification
            print_status "Creating temporary NGINX configuration for Let's Encrypt..."
            mkdir -p /var/www/html/.well-known/acme-challenge
            chmod -R 755 /var/www/html
            chown -R www-data:www-data /var/www/html
            
            # Temporary Mattermost config (HTTP only)
            cat > ${NGINX_CONF_DIR}/sites-available/mattermost <<EOF
upstream mattermost {
    server 127.0.0.1:8065;
    keepalive 32;
}

server {
    listen 80;
    server_name ${MATTERMOST_DOMAIN};
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://mattermost;
    }
}
EOF
            
            # Temporary Jitsi config (HTTP only) if needed
            if [ "$INSTALL_JITSI" = "yes" ]; then
                cat > ${NGINX_CONF_DIR}/sites-available/jitsi <<EOF
server {
    listen 80;
    server_name ${JITSI_DOMAIN};
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
    }
}
EOF
            fi
            
            # Enable sites
            ln -sf ${NGINX_CONF_DIR}/sites-available/mattermost ${NGINX_CONF_DIR}/sites-enabled/mattermost
            if [ "$INSTALL_JITSI" = "yes" ]; then
                ln -sf ${NGINX_CONF_DIR}/sites-available/jitsi ${NGINX_CONF_DIR}/sites-enabled/jitsi
            fi
            
            # Reload NGINX with temporary config
            nginx -t && systemctl reload nginx
            print_success "Temporary NGINX configuration loaded"
        fi
        
        # Now get SSL certificates
        setup_ssl_certificates
    fi
    
    # Configure NGINX for services (final config with HTTPS if applicable)
    configure_nginx_mattermost
    if [ "$INSTALL_JITSI" = "yes" ]; then
        configure_nginx_jitsi
    fi
    reload_nginx
    
    # Install Mattermost
    create_mattermost_compose
    start_mattermost
    
    # Install Jitsi
    if [ "$INSTALL_JITSI" = "yes" ]; then
        create_jitsi_env
        create_jitsi_compose
        start_jitsi
    fi
    
    # Save credentials
    save_credentials
    
    # Display summary
    display_summary
    
    print_status "Installation completed at $(date)" | tee -a "$LOG_FILE"
}

# Run main function
main "$@"
