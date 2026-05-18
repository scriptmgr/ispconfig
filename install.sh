#!/bin/bash

# Universal ISPConfig Installation Script
# Architecture: Nginx (frontend, SSL termination) → Apache (backend, 127.0.0.1:81)
# Run as root: bash install.sh

set -e

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# ── Global variables ──────────────────────────────────────────────────────────
ADMIN_PORT=64245
MYSQL_ROOT_PASSWORD=""
ISPCONFIG_ADMIN_PASSWORD=""
ISPCONFIG_DB_PASSWORD=""
HOSTNAME=""
DISTRO=""
DISTRO_VERSION=""
PACKAGE_MANAGER=""
SERVICE_MANAGER="systemctl"
PHP_DEFAULT="8.3"   # fallback; overwritten after install to highest available version
PHP_VERSIONS=("8.4" "8.3" "8.2" "8.1" "8.0" "7.4" "7.3" "7.2" "7.1" "7.0" "5.6")

# Reverse proxy settings
APACHE_BACKEND_IP="127.0.0.1"
APACHE_BACKEND_PORT="81"
APACHE_ADMIN_PORT="7080"
APACHE_APPS_PORT="7081"
NGINX_VHOSTS_DIR="/etc/nginx/vhosts.d"
LETSENCRYPT_WEBROOT="/var/www/letsencrypt"
SSL_DIR="/etc/ssl/ispconfig"

# Set by __validate_distro
NGINX_USER=""
SSL_CA_BUNDLE=""
APACHE_SERVICE=""
APACHE_CONF_DIR=""
APACHE_VHOST_DIR=""
APACHE_CONF_EXTRA=""

# ── Logging ───────────────────────────────────────────────────────────────────
log()     { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
success() { echo -e "${BLUE}[SUCCESS]${NC} $1"; }

# ── Root check ────────────────────────────────────────────────────────────────
__check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

# ── Distro detection ──────────────────────────────────────────────────────────
__detect_distro() {
    log "Detecting Linux distribution..."
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO="$ID"
        DISTRO_VERSION="$VERSION_ID"
    elif [[ -f /etc/debian_version ]]; then
        DISTRO="debian"
        DISTRO_VERSION=$(cat /etc/debian_version)
    elif [[ -f /etc/redhat-release ]]; then
        grep -q "CentOS"    /etc/redhat-release && DISTRO="centos"
        grep -q "Red Hat"   /etc/redhat-release && DISTRO="rhel"
        grep -q "AlmaLinux" /etc/redhat-release && DISTRO="almalinux"
        grep -q "Rocky"     /etc/redhat-release && DISTRO="rocky"
        DISTRO_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
    else
        error "Cannot detect Linux distribution"
    fi
    log "Detected: $DISTRO $DISTRO_VERSION"
    __validate_distro
}

__validate_distro() {
    local supported=false
    case "$DISTRO" in
        "ubuntu")
            [[ "$DISTRO_VERSION" =~ ^(18|20|22|24|25|26) ]] && supported=true && PACKAGE_MANAGER="apt"
            NGINX_USER="www-data"
            SSL_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
            APACHE_SERVICE="apache2"
            APACHE_CONF_DIR="/etc/apache2"
            APACHE_VHOST_DIR="/etc/apache2/sites-available"
            APACHE_CONF_EXTRA="/etc/apache2/conf-available"
            ;;
        "debian")
            [[ "$DISTRO_VERSION" =~ ^(9|10|11|12|13) ]] && supported=true && PACKAGE_MANAGER="apt"
            NGINX_USER="www-data"
            SSL_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
            APACHE_SERVICE="apache2"
            APACHE_CONF_DIR="/etc/apache2"
            APACHE_VHOST_DIR="/etc/apache2/sites-available"
            APACHE_CONF_EXTRA="/etc/apache2/conf-available"
            ;;
        "centos"|"rhel")
            if [[ "$DISTRO_VERSION" =~ ^(7|8|9) ]]; then
                supported=true
                PACKAGE_MANAGER="yum"
                [[ "$DISTRO_VERSION" =~ ^(8|9) ]] && PACKAGE_MANAGER="dnf"
            fi
            NGINX_USER="nginx"
            SSL_CA_BUNDLE="/etc/pki/tls/certs/ca-bundle.crt"
            APACHE_SERVICE="httpd"
            APACHE_CONF_DIR="/etc/httpd"
            APACHE_VHOST_DIR="/etc/httpd/conf.d"
            APACHE_CONF_EXTRA="/etc/httpd/conf.d"
            ;;
        "almalinux"|"rocky")
            [[ "$DISTRO_VERSION" =~ ^(8|9|10) ]] && supported=true && PACKAGE_MANAGER="dnf"
            NGINX_USER="nginx"
            SSL_CA_BUNDLE="/etc/pki/tls/certs/ca-bundle.crt"
            APACHE_SERVICE="httpd"
            APACHE_CONF_DIR="/etc/httpd"
            APACHE_VHOST_DIR="/etc/httpd/conf.d"
            APACHE_CONF_EXTRA="/etc/httpd/conf.d"
            ;;
        "fedora")
            [[ "$DISTRO_VERSION" =~ ^(3[6-9]|4[0-9]) ]] && supported=true && PACKAGE_MANAGER="dnf"
            NGINX_USER="nginx"
            SSL_CA_BUNDLE="/etc/pki/tls/certs/ca-bundle.crt"
            APACHE_SERVICE="httpd"
            APACHE_CONF_DIR="/etc/httpd"
            APACHE_VHOST_DIR="/etc/httpd/conf.d"
            APACHE_CONF_EXTRA="/etc/httpd/conf.d"
            ;;
        "opensuse"|"opensuse-leap"|"sles")
            [[ "$DISTRO_VERSION" =~ ^(15|42) ]] && supported=true && PACKAGE_MANAGER="zypper"
            NGINX_USER="nginx"
            SSL_CA_BUNDLE="/etc/ssl/ca-bundle.pem"
            APACHE_SERVICE="apache2"
            APACHE_CONF_DIR="/etc/apache2"
            APACHE_VHOST_DIR="/etc/apache2/vhosts.d"
            APACHE_CONF_EXTRA="/etc/apache2/conf.d"
            ;;
    esac

    if [[ "$supported" != "true" ]]; then
        error "Unsupported distribution: $DISTRO $DISTRO_VERSION
Supported: Ubuntu 18-26, Debian 9-13, CentOS/RHEL 7-9, AlmaLinux/Rocky 8-10, Fedora 36-49, openSUSE Leap 15.x"
    fi
    success "Distribution $DISTRO $DISTRO_VERSION is supported (${PACKAGE_MANAGER})"
}

# ── Passwords ─────────────────────────────────────────────────────────────────
__generate_passwords() {
    if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
        MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)
        log "Generated MySQL root password"
    fi
    if [[ -z "$ISPCONFIG_ADMIN_PASSWORD" ]]; then
        ISPCONFIG_ADMIN_PASSWORD=$(openssl rand -base64 32)
        log "Generated ISPConfig admin password"
    fi
    if [[ -z "$ISPCONFIG_DB_PASSWORD" ]]; then
        ISPCONFIG_DB_PASSWORD=$(openssl rand -base64 32)
        log "Generated ISPConfig DB user password"
    fi
}

# ── Hostname ──────────────────────────────────────────────────────────────────
__set_hostname() {
    if [[ -z "$HOSTNAME" ]]; then
        local sys_host domain
        sys_host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo 'server')
        domain=$(hostname -d 2>/dev/null)
        [[ -z "$domain" ]] && domain="local"
        HOSTNAME="${sys_host}.${domain}"
    fi
    # Ensure HOSTNAME includes a domain component
    [[ "$HOSTNAME" != *.* ]] && HOSTNAME="${HOSTNAME}.local"

    local base_hostname="${HOSTNAME%%.*}"

    # Set static hostname (persists across reboots)
    hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || echo "$HOSTNAME" > /etc/hostname
    # Set runtime hostname immediately (so hostname -f works before reboot)
    hostname "$HOSTNAME" 2>/dev/null || true

    # Update /etc/hosts so FQDN resolves correctly (required by postfix, ISPConfig)
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip="127.0.1.1"
    sed -i "/[[:space:]]${base_hostname}\b/d" /etc/hosts
    echo "${ip}    ${HOSTNAME} ${base_hostname}" >> /etc/hosts

    log "Hostname configured: ${HOSTNAME}"
}

# ── System update ─────────────────────────────────────────────────────────────
__update_system() {
    log "Updating system packages..."
    case "$PACKAGE_MANAGER" in
        "apt")
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get upgrade -y
            apt-get install -y ca-certificates gnupg lsb-release curl wget
            if [[ "$DISTRO" == "ubuntu" ]]; then
                apt-get install -y software-properties-common
            fi
            ;;
        "dnf")
            dnf update -y
            dnf install -y epel-release
            ;;
        "yum")
            yum update -y
            yum install -y epel-release
            ;;
        "zypper")
            zypper refresh
            zypper update -y
            ;;
    esac
}

# ── Base packages ─────────────────────────────────────────────────────────────
__install_base_packages() {
    log "Installing base packages..."
    case "$PACKAGE_MANAGER" in
        "apt")
            apt-get install -y wget curl vim net-tools dnsutils openssl ssl-cert
            ;;
        "dnf"|"yum")
            $PACKAGE_MANAGER install -y wget curl vim net-tools bind-utils openssl
            ;;
        "zypper")
            zypper install -y wget curl vim net-tools bind-utils openssl
            ;;
    esac
}

# ── Firewall ──────────────────────────────────────────────────────────────────
__configure_firewall() {
    log "Configuring firewall..."
    case "$DISTRO" in
        "ubuntu"|"debian")
            command -v ufw &>/dev/null || apt-get install -y ufw
            ufw --force enable
            for port in ssh http https ftp; do ufw allow $port; done
            for port in 21 25 110 143 465 587 993 995 53 $ADMIN_PORT; do ufw allow ${port}/tcp; done
            ufw allow 53/udp
            ufw allow 49152:65534/tcp
            ;;
        *)
            if command -v firewall-cmd &>/dev/null; then
                systemctl enable firewalld && systemctl start firewalld
                for svc in http https ssh ftp smtp pop3 imap smtps pop3s imaps dns; do
                    firewall-cmd --permanent --add-service=$svc
                done
                for port in 21 49152-65534 ${ADMIN_PORT} 587; do
                    firewall-cmd --permanent --add-port=${port}/tcp
                done
                firewall-cmd --reload
            fi
            ;;
    esac
}

# ── Nginx install + config ────────────────────────────────────────────────────
__install_nginx() {
    log "Installing Nginx..."
    case "$PACKAGE_MANAGER" in
        "apt")
            apt-get install -y nginx
            ;;
        "dnf"|"yum")
            $PACKAGE_MANAGER install -y nginx
            ;;
        "zypper")
            zypper install -y nginx
            ;;
    esac

    # Stop nginx immediately — it will be started last in __final_configuration
    # once Apache is already running on the backend port.
    systemctl stop nginx 2>/dev/null || true

    log "Building Nginx configuration..."

    # Wipe everything except mime.types
    find /etc/nginx -mindepth 1 -maxdepth 1 ! -name 'mime.types' -exec rm -rf {} \;

    mkdir -p "$NGINX_VHOSTS_DIR"
    mkdir -p "$LETSENCRYPT_WEBROOT/.well-known/acme-challenge"
    chown -R "$NGINX_USER:$NGINX_USER" "$LETSENCRYPT_WEBROOT" 2>/dev/null || true

    # ── nginx.conf ────────────────────────────────────────────────────────────
    cat > /etc/nginx/nginx.conf << 'NGINX_EOF'
user NGINX_USER_PLACEHOLDER;
worker_processes auto;
worker_cpu_affinity auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

events {
    worker_connections  65535;
    use                 epoll;
    multi_accept        on;
}

http {
    charset             utf-8;
    include             mime.types;
    default_type        application/octet-stream;
    server_tokens       off;

    # ── Logging ───────────────────────────────────────────────────────────────
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main buffer=32k flush=5m;
    error_log   /var/log/nginx/error.log   warn;

    # ── Performance ───────────────────────────────────────────────────────────
    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    keepalive_requests  10000;
    reset_timedout_connection on;
    client_body_timeout 30;
    client_header_timeout 30;
    send_timeout        30;

    # ── Buffers ───────────────────────────────────────────────────────────────
    client_body_buffer_size     128k;
    client_max_body_size        100m;
    client_header_buffer_size   1k;
    large_client_header_buffers 4 16k;
    output_buffers              2 32k;
    postpone_output             1460;

    # ── File cache ────────────────────────────────────────────────────────────
    open_file_cache          max=200000 inactive=20s;
    open_file_cache_valid    30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors   on;

    # ── Gzip ──────────────────────────────────────────────────────────────────
    gzip              on;
    gzip_vary         on;
    gzip_proxied      any;
    gzip_comp_level   6;
    gzip_buffers      16 8k;
    gzip_http_version 1.1;
    gzip_min_length   256;
    gzip_types
        application/atom+xml application/geo+json application/javascript
        application/x-javascript application/json application/ld+json
        application/manifest+json application/rdf+xml application/rss+xml
        application/xhtml+xml application/xml font/eot font/otf font/ttf
        image/svg+xml text/css text/javascript text/plain text/xml;

    # ── Proxy defaults (inherited by all proxy_pass locations) ────────────────
    proxy_http_version          1.1;
    proxy_set_header Host       $http_host;
    proxy_set_header X-Real-IP  $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host  $http_host;
    proxy_set_header X-Forwarded-Port  $server_port;
    proxy_set_header Connection "";
    proxy_redirect              off;
    proxy_connect_timeout       60s;
    proxy_send_timeout          60s;
    proxy_read_timeout          60s;
    proxy_buffer_size           16k;
    proxy_buffers               4 64k;
    proxy_busy_buffers_size     128k;
    proxy_temp_file_write_size  128k;
    proxy_cache_bypass          $http_upgrade;
    proxy_intercept_errors      off;

    # ── SSL global ────────────────────────────────────────────────────────────
    ssl_protocols               TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers   on;
    ssl_ciphers                 ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_dhparam                 /etc/nginx/dhparam.pem;
    ssl_ecdh_curve              secp384r1;
    ssl_session_cache           shared:SSL:50m;
    ssl_session_timeout         1d;
    ssl_session_tickets         off;
    ssl_stapling                on;
    ssl_stapling_verify         on;
    ssl_trusted_certificate     SSL_CA_BUNDLE_PLACEHOLDER;
    resolver                    1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout            5s;

    # ── Apache backend upstream ───────────────────────────────────────────────
    upstream apache_backend {
        server      APACHE_BACKEND_IP_PLACEHOLDER:APACHE_BACKEND_PORT_PLACEHOLDER;
        keepalive   64;
    }

    # ── ISPConfig admin upstream ──────────────────────────────────────────────
    upstream ispconfig_admin {
        server      APACHE_BACKEND_IP_PLACEHOLDER:APACHE_ADMIN_PORT_PLACEHOLDER;
        keepalive   8;
    }

    include NGINX_VHOSTS_DIR_PLACEHOLDER/*.conf;
}
NGINX_EOF

    sed -i \
        -e "s|NGINX_USER_PLACEHOLDER|${NGINX_USER}|g" \
        -e "s|SSL_CA_BUNDLE_PLACEHOLDER|${SSL_CA_BUNDLE}|g" \
        -e "s|APACHE_BACKEND_IP_PLACEHOLDER|${APACHE_BACKEND_IP}|g" \
        -e "s|APACHE_BACKEND_PORT_PLACEHOLDER|${APACHE_BACKEND_PORT}|g" \
        -e "s|APACHE_ADMIN_PORT_PLACEHOLDER|${APACHE_ADMIN_PORT}|g" \
        -e "s|NGINX_VHOSTS_DIR_PLACEHOLDER|${NGINX_VHOSTS_DIR}|g" \
        /etc/nginx/nginx.conf

    # ── vhosts.d/00-redirect-http.conf ───────────────────────────────────────
    cat > "${NGINX_VHOSTS_DIR}/00-redirect-http.conf" << VHOST_EOF
server {
    listen      80 default_server;
    listen      [::]:80 default_server;
    server_name _;

    # ACME challenge for Let's Encrypt (served before redirect)
    location ^~ /.well-known/acme-challenge/ {
        root  ${LETSENCRYPT_WEBROOT};
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
VHOST_EOF

    # ── vhosts.d/00-default-https.conf ───────────────────────────────────────
    cat > "${NGINX_VHOSTS_DIR}/00-default-https.conf" << VHOST_EOF
server {
    listen      443 ssl http2 default_server;
    listen      [::]:443 ssl http2 default_server;
    server_name _;

    ssl_certificate     ${SSL_DIR}/default.crt;
    ssl_certificate_key ${SSL_DIR}/default.key;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options    nosniff always;
    add_header X-Frame-Options           SAMEORIGIN always;
    add_header X-XSS-Protection          "1; mode=block" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;

    # ACME challenge
    location ^~ /.well-known/acme-challenge/ {
        root  ${LETSENCRYPT_WEBROOT};
        default_type text/plain;
        try_files \$uri =404;
    }

    # Static asset caching (served via Apache but cached at edge)
    location ~* \.(jpg|jpeg|gif|png|ico|svg|webp|css|js|woff|woff2|ttf|eot)\$ {
        proxy_pass         http://apache_backend;
        expires            30d;
        add_header         Cache-Control "public, no-transform";
        proxy_cache_bypass 0;
    }

    location / {
        proxy_pass http://apache_backend;
    }
}
VHOST_EOF

    log "Nginx installed and configured (vhosts.d panel vhost added post-ISPConfig)"
    systemctl enable nginx
}

# ── Apache install ────────────────────────────────────────────────────────────
__install_apache() {
    log "Installing Apache web server..."
    case "$PACKAGE_MANAGER" in
        "apt")
            apt-get install -y apache2 apache2-utils libapache2-mod-fcgid apache2-suexec-pristine
            a2enmod rewrite fcgid actions alias suexec
            systemctl enable apache2
            systemctl start apache2
            ;;
        "dnf"|"yum")
            $PACKAGE_MANAGER install -y httpd mod_fcgid
            systemctl enable httpd
            systemctl start httpd
            ;;
        "zypper")
            zypper install -y apache2 apache2-mod_fcgid
            systemctl enable apache2
            systemctl start apache2
            ;;
    esac
}

# ── MariaDB ───────────────────────────────────────────────────────────────────
__install_mysql() {
    log "Installing MariaDB server..."
    case "$PACKAGE_MANAGER" in
        "apt")       apt-get install -y mariadb-server mariadb-client ;;
        "dnf"|"yum") $PACKAGE_MANAGER install -y mariadb-server mariadb ;;
        "zypper")    zypper install -y mariadb mariadb-client ;;
    esac

    systemctl enable mariadb
    systemctl start mariadb

    # Prefer 'mariadb' binary (MariaDB 10.4+), fall back to 'mysql'
    local MYSQL_BIN="mysql"
    command -v mariadb >/dev/null 2>&1 && MYSQL_BIN="mariadb"

    log "Securing MariaDB (${MYSQL_BIN})..."

    # Determine how to connect for initial setup.
    # Debian 10.4+ maps unix_socket auth to the 'mysql' OS user, not 'root'.
    # RHEL/older systems allow OS root to connect directly via socket.
    local INIT_CMD=""
    if runuser -u mysql -- ${MYSQL_BIN} -e "SELECT 1" >/dev/null 2>&1; then
        INIT_CMD="runuser -u mysql -- ${MYSQL_BIN}"
    elif ${MYSQL_BIN} -e "SELECT 1" >/dev/null 2>&1; then
        INIT_CMD="${MYSQL_BIN}"
    else
        error "Cannot connect to MariaDB for initial setup — check installation"
    fi

    # Set root password, trying modern then legacy syntax
    ${INIT_CMD} -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}'" 2>/dev/null || \
    ${INIT_CMD} -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${MYSQL_ROOT_PASSWORD}')" 2>/dev/null || \
    ${INIT_CMD} -e "UPDATE mysql.user SET Password=PASSWORD('${MYSQL_ROOT_PASSWORD}') WHERE User='root'; FLUSH PRIVILEGES;"

    # All subsequent operations use password auth
    local MYSQL="${MYSQL_BIN} -u root -p${MYSQL_ROOT_PASSWORD}"
    ${MYSQL} -e "DELETE FROM mysql.user WHERE User=''"
    ${MYSQL} -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1')"
    ${MYSQL} -e "DROP DATABASE IF EXISTS test"
    ${MYSQL} -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'"
    ${MYSQL} -e "FLUSH PRIVILEGES"

    cat > /root/.my.cnf << EOF
[client]
user=root
password=${MYSQL_ROOT_PASSWORD}
EOF
    chmod 600 /root/.my.cnf
    success "MariaDB secured"
}

# ── PHP ───────────────────────────────────────────────────────────────────────
__install_php() {
    log "Installing multiple PHP versions..."
    case "$DISTRO" in
        "ubuntu"|"debian")            __install_php_debian ;;
        "centos"|"rhel"|"almalinux"|"rocky"|"fedora") __install_php_rhel ;;
        "opensuse"|"opensuse-leap"|"sles") __install_php_suse ;;
    esac
    __configure_php_versions
}

__install_php_debian() {
    log "Adding Ondrej PHP repository..."
    if [[ "$DISTRO" == "ubuntu" ]]; then
        add-apt-repository -y ppa:ondrej/php
        # If this Ubuntu codename is not yet in the PPA (brand-new release), fall back to
        # the previous LTS codename (noble/24.04) which ships binary-compatible packages.
        local _codename
        _codename=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")
        if [[ -n "$_codename" ]]; then
            if ! curl -sfI \
                    "https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/${_codename}/Release" \
                    >/dev/null 2>&1; then
                warn "Ondrej PPA has no release for '${_codename}' — using noble (24.04) packages"
                local _src
                _src=$(find /etc/apt/sources.list.d/ -name 'ondrej*php*' | head -1)
                if [[ -n "$_src" ]]; then
                    sed -i "s/Suites: ${_codename}/Suites: noble/g" "$_src"
                    sed -i "s/ ${_codename} / noble /g" "$_src"
                fi
            fi
        fi
    else
        wget -qO /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
        echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
    fi
    apt-get update

    # Prevent package post-install scripts from starting services (avoids "Cannot fork"
    # errors in containers where fork is restricted during dpkg script execution)
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d

    for version in "${PHP_VERSIONS[@]}"; do
        # Skip versions not available in the configured repos
        if ! apt-cache show "php${version}" >/dev/null 2>&1; then
            warn "PHP ${version} not available in repos — skipping"
            continue
        fi
        log "Installing PHP ${version}..."

        # Core packages — required for every version
        # Note: php${version}-pcntl is NOT a separate package on Ondrej PPA;
        # PCNTL is compiled into the PHP CLI binary directly.
        if ! apt-get install -y \
            php${version} php${version}-cli php${version}-fpm php${version}-cgi \
            php${version}-common php${version}-mysql php${version}-pgsql \
            php${version}-sqlite3 php${version}-gd php${version}-imagick \
            php${version}-mbstring php${version}-xml php${version}-curl \
            php${version}-zip php${version}-soap php${version}-intl \
            php${version}-bcmath php${version}-opcache php${version}-readline \
            php${version}-bz2 php${version}-xsl php${version}-tidy \
            php${version}-ldap php${version}-imap php${version}-gettext \
            php${version}-exif php${version}-sockets \
            php${version}-redis php${version}-memcached; then
            warn "PHP ${version} install had errors — attempting dpkg repair"
            apt-get install -f -y 2>/dev/null || true
        fi

        # json is a separate package on PHP < 8.0 (built-in from 8.0 onward)
        if dpkg --compare-versions "${version}" lt "8.0" 2>/dev/null; then
            apt-get install -y php${version}-json 2>/dev/null || true
        fi
    done

    # Remove policy block and start FPM services now
    rm -f /usr/sbin/policy-rc.d

    # Pick the highest installed version as the system default (PHP_VERSIONS is ordered
    # highest-first, so the first binary we find is the best available version)
    for version in "${PHP_VERSIONS[@]}"; do
        if [[ -x "/usr/bin/php${version}" ]]; then
            PHP_DEFAULT="$version"
            break
        fi
    done
    log "Setting PHP ${PHP_DEFAULT} as system default"
    update-alternatives --set php     "/usr/bin/php${PHP_DEFAULT}"     2>/dev/null || true
    update-alternatives --set php-cgi "/usr/bin/php-cgi${PHP_DEFAULT}" 2>/dev/null || true

    for version in "${PHP_VERSIONS[@]}"; do
        systemctl enable php${version}-fpm 2>/dev/null || true
        systemctl start  php${version}-fpm 2>/dev/null || true
    done
}

__install_php_rhel() {
    log "Adding Remi PHP repository..."
    local major_version
    major_version=$(echo "$DISTRO_VERSION" | cut -d. -f1)
    $PACKAGE_MANAGER install -y "https://rpms.remirepo.net/enterprise/remi-release-${major_version}.rpm" 2>/dev/null || \
        warn "Remi repo install failed for version ${major_version}"

    for version in "${PHP_VERSIONS[@]}"; do
        local vc=${version//./}
        # Skip versions not available in Remi
        if ! $PACKAGE_MANAGER info --enablerepo=remi "php${vc}" >/dev/null 2>&1; then
            warn "PHP ${version} not available in Remi — skipping"
            continue
        fi
        log "Installing PHP ${version}..."
        if ! $PACKAGE_MANAGER install -y --enablerepo=remi \
            php${vc} php${vc}-php-cli php${vc}-php-fpm php${vc}-php-cgi \
            php${vc}-php-common php${vc}-php-mysqlnd php${vc}-php-pgsql \
            php${vc}-php-pdo php${vc}-php-gd php${vc}-php-pecl-imagick \
            php${vc}-php-mbstring php${vc}-php-xml php${vc}-php-curl \
            php${vc}-php-zip php${vc}-php-soap php${vc}-php-intl \
            php${vc}-php-bcmath php${vc}-php-opcache php${vc}-php-readline \
            php${vc}-php-bz2 php${vc}-php-ldap php${vc}-php-imap \
            php${vc}-php-pecl-redis php${vc}-php-pecl-memcached \
            php${vc}-php-tidy php${vc}-php-exif php${vc}-php-sockets \
            php${vc}-php-pcntl php${vc}-php-sqlite3; then
            warn "PHP ${version} install had errors — some modules may be missing"
        fi
        ln -sf /opt/remi/php${vc}/root/usr/bin/php /usr/local/bin/php${version} 2>/dev/null || true
        systemctl enable php${vc}-php-fpm 2>/dev/null || true
        systemctl start  php${vc}-php-fpm 2>/dev/null || true
    done
    # Pick highest installed version as default
    for version in "${PHP_VERSIONS[@]}"; do
        local vc="${version//./}"
        if [[ -x "/opt/remi/php${vc}/root/usr/bin/php" ]]; then
            PHP_DEFAULT="$version"
            break
        fi
    done
    local dvc="${PHP_DEFAULT//./}"
    log "Setting PHP ${PHP_DEFAULT} as system default"
    alternatives --install /usr/bin/php php /opt/remi/php${dvc}/root/usr/bin/php 100 2>/dev/null || true
}

__install_php_suse() {
    local available=("8.2" "8.1" "8.0" "7.4")
    for version in "${available[@]}"; do
        local vc=${version//./}
        log "Installing PHP ${version}..."
        zypper install -y \
            php${vc} php${vc}-cli php${vc}-fpm php${vc}-mysql \
            php${vc}-gd php${vc}-mbstring php${vc}-xml php${vc}-curl \
            php${vc}-zip php${vc}-soap php${vc}-intl php${vc}-bcmath \
            php${vc}-opcache 2>/dev/null || warn "Some PHP ${version} packages unavailable"
        systemctl enable php-fpm 2>/dev/null || true
        systemctl start  php-fpm 2>/dev/null || true
    done
}

__configure_php_versions() {
    log "Tuning PHP ini files..."
    while IFS= read -r -d '' php_ini; do
        sed -i \
            -e 's/^;date.timezone =.*/date.timezone = UTC/' \
            -e 's/^upload_max_filesize = .*/upload_max_filesize = 100M/' \
            -e 's/^post_max_size = .*/post_max_size = 100M/' \
            -e 's/^max_execution_time = .*/max_execution_time = 300/' \
            -e 's/^memory_limit = .*/memory_limit = 256M/' \
            -e 's/^;max_input_vars = .*/max_input_vars = 10000/' \
            -e 's/^max_input_vars = .*/max_input_vars = 10000/' \
            -e 's/^;log_errors = .*/log_errors = On/' \
            "$php_ini"
    done < <(find /etc -name "php.ini" -print0 2>/dev/null)
}

# ── Mail ──────────────────────────────────────────────────────────────────────
__install_mail() {
    log "Installing mail services (Postfix + Dovecot)..."
    case "$PACKAGE_MANAGER" in
        "apt")
            # Required — script fails if these are missing
            apt-get install -y \
                postfix postfix-mysql postfix-pcre \
                dovecot-core dovecot-imapd dovecot-pop3d \
                dovecot-mysql dovecot-sieve dovecot-lmtpd dovecot-managesieved \
                libsasl2-modules libsasl2-2 sasl2-bin
            # Optional — DKIM; warn and continue if unavailable
            apt-get install -y opendkim opendkim-tools \
                || warn "opendkim not available — DKIM will be skipped"
            ;;
        "dnf"|"yum")
            # CRB (CodeReady Builder / powertools) is required for sendmail-milter
            # and libmemcached-awesome which are opendkim dependencies on el8/el9.
            dnf config-manager --set-enabled crb 2>/dev/null \
                || dnf config-manager --set-enabled powertools 2>/dev/null \
                || true
            # Required
            $PACKAGE_MANAGER install -y \
                postfix postfix-mysql postfix-pcre \
                dovecot dovecot-mysql dovecot-pigeonhole \
                cyrus-sasl cyrus-sasl-plain cyrus-sasl-md5
            # opendkim on RHEL needs libmilter (sendmail-milter, CRB) and
            # libmemcached-awesome (CRB); package name changed from libmemcached in el9
            $PACKAGE_MANAGER install -y sendmail-milter 2>/dev/null || true
            $PACKAGE_MANAGER install -y libmemcached-awesome 2>/dev/null \
                || $PACKAGE_MANAGER install -y libmemcached 2>/dev/null || true
            $PACKAGE_MANAGER install -y opendkim opendkim-tools \
                || warn "opendkim not available — DKIM will be skipped"
            ;;
        "zypper")
            zypper install -y \
                postfix postfix-mysql \
                dovecot dovecot-backend-mysql
            zypper install -y opendkim 2>/dev/null \
                || warn "opendkim not available — DKIM will be skipped"
            ;;
    esac
    systemctl enable postfix dovecot
    systemctl start  postfix dovecot
}

__configure_mail_public() {
    log "Configuring mail for public use (inbound + outbound + secure retrieval)..."

    # ── Postfix: TLS and delivery hardening ──────────────────────────────────
    # Use ISPConfig's SSL cert for mail TLS (already created by ISPConfig install)
    local mail_cert="/usr/local/ispconfig/interface/ssl/ispserver.crt"
    local mail_key="/usr/local/ispconfig/interface/ssl/ispserver.key"

    # Outbound: opportunistic TLS — required by Gmail, Yahoo, Outlook, etc.
    postconf -e "smtp_tls_security_level = may"
    postconf -e "smtp_tls_loglevel = 1"
    postconf -e "smtp_tls_CAfile = ${SSL_CA_BUNDLE}"

    # Inbound: offer STARTTLS to connecting clients
    postconf -e "smtpd_tls_security_level = may"
    postconf -e "smtpd_tls_auth_only = yes"
    postconf -e "smtpd_tls_loglevel = 1"
    if [[ -f "$mail_cert" && -f "$mail_key" ]]; then
        postconf -e "smtpd_tls_cert_file = ${mail_cert}"
        postconf -e "smtpd_tls_key_file = ${mail_key}"
    fi

    # Protocol and cipher hardening
    postconf -e "smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
    postconf -e "smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
    postconf -e "smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
    postconf -e "smtp_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
    postconf -e "tls_preempt_cipherlist = no"

    # Message limits
    postconf -e "message_size_limit = 52428800"
    postconf -e "mailbox_size_limit = 0"
    postconf -e "recipient_delimiter = +"

    # Anti-spam: require HELO, validate sender domains
    postconf -e "smtpd_helo_required = yes"
    postconf -e "smtpd_delay_reject = yes"

    # ── Postfix master.cf: ensure submission (587) and smtps (465) are active ─
    if ! grep -q "^submission " /etc/postfix/master.cf; then
        cat >> /etc/postfix/master.cf << 'MASTEREOF'
submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
MASTEREOF
        log "Enabled SMTP submission on port 587"
    fi

    if ! grep -q "^smtps " /etc/postfix/master.cf; then
        cat >> /etc/postfix/master.cf << 'MASTEREOF'
smtps inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
MASTEREOF
        log "Enabled SMTPS on port 465"
    fi

    # ── Dovecot: SSL and secure-listener hardening ───────────────────────────
    local dovecot_ssl_conf="/etc/dovecot/conf.d/10-ssl.conf"
    if [[ -f "$dovecot_ssl_conf" ]]; then
        # Enable SSL, set minimum TLS version, use ISPConfig's cert
        sed -i \
            -e "s|^ssl = .*|ssl = yes|" \
            -e "s|^#ssl = .*|ssl = yes|" \
            "$dovecot_ssl_conf"
        if [[ -f "$mail_cert" && -f "$mail_key" ]]; then
            sed -i \
                -e "s|^ssl_cert = .*|ssl_cert = <${mail_cert}|" \
                -e "s|^ssl_key = .*|ssl_key = <${mail_key}|" \
                "$dovecot_ssl_conf"
        fi
        if grep -q "ssl_min_protocol\|ssl_protocols" "$dovecot_ssl_conf"; then
            sed -i \
                -e "s|^ssl_min_protocol = .*|ssl_min_protocol = TLSv1.2|" \
                -e "s|^ssl_protocols = .*|ssl_min_protocol = TLSv1.2|" \
                "$dovecot_ssl_conf"
        else
            echo "ssl_min_protocol = TLSv1.2" >> "$dovecot_ssl_conf"
        fi
    fi

    # ── OpenDKIM: framework setup (keys generated per-domain via ISPConfig UI) ─
    local dkim_dir="/etc/opendkim"
    local dkim_keys_dir="/etc/opendkim/keys"
    mkdir -p "$dkim_keys_dir"

    if [[ -f /etc/opendkim.conf ]]; then
        # Locate the DNSSEC trust anchor — path differs by distro/package.
        # TrustAnchorFile is optional; omit it when not present rather than
        # hard-coding a path that may not exist (RHEL installs to a different
        # location than Debian's /usr/share/dns/root.key).
        local trust_anchor=""
        for _ta in /usr/share/dns/root.key \
                   /usr/share/dns-root-data/root.key \
                   /var/lib/unbound/root.key \
                   /etc/unbound/root.key; do
            if [[ -f "$_ta" ]]; then
                trust_anchor="TrustAnchorFile         ${_ta}"
                break
            fi
        done

        cat > /etc/opendkim.conf << DKIMEOF
Syslog                  yes
SyslogSuccess           yes
LogWhy                  yes
Canonicalization        relaxed/simple
Mode                    sv
SubDomains              no
AutoRestart             yes
AutoRestartRate         10/1M
Background              yes
DNSTimeout              5
SignatureAlgorithm      rsa-sha256
UserID                  opendkim:opendkim
UMask                   007
Socket                  inet:8891@localhost
PidFile                 /run/opendkim/opendkim.pid
${trust_anchor}
KeyTable                /etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
ExternalIgnoreList      /etc/opendkim/TrustedHosts
InternalHosts           /etc/opendkim/TrustedHosts
DKIMEOF
    fi

    touch /etc/opendkim/KeyTable /etc/opendkim/SigningTable 2>/dev/null || true
    cat > /etc/opendkim/TrustedHosts << TRUSTEOF
127.0.0.1
::1
localhost
${HOSTNAME}
TRUSTEOF

    chown -R opendkim:opendkim "$dkim_dir" 2>/dev/null || true
    chmod 750 "$dkim_keys_dir" 2>/dev/null || true

    # Wire OpenDKIM milter into Postfix
    postconf -e "milter_protocol = 6"
    postconf -e "milter_default_action = accept"
    if ! postconf smtpd_milters 2>/dev/null | grep -q "8891"; then
        postconf -e "smtpd_milters = inet:localhost:8891"
        postconf -e "non_smtpd_milters = inet:localhost:8891"
    fi

    systemctl enable opendkim 2>/dev/null || true
    systemctl start  opendkim 2>/dev/null || true

    systemctl restart postfix dovecot 2>/dev/null || true
    success "Mail configured: SMTP/S + submission + IMAP/S + POP3/S + DKIM framework"
}

# ── FTP ───────────────────────────────────────────────────────────────────────
__install_ftp() {
    log "Installing ProFTPd..."
    case "$PACKAGE_MANAGER" in
        "apt")
            # proftpd-mod-mysql is a separate package on some Debian versions but
            # may be merged into proftpd or absent on others — treat it as optional
            apt-get install -y proftpd-basic \
                || apt-get install -y proftpd \
                || warn "proftpd install failed — FTP may not be available"
            apt-get install -y proftpd-mod-mysql 2>/dev/null \
                || warn "proftpd-mod-mysql unavailable — MySQL-based FTP auth disabled"
            ;;
        "dnf"|"yum")
            # proftpd on EPEL 9 depends on libmemcached which is in CRB (CodeReady Builder).
            # Enable CRB first, install the dep, then try proftpd normally;
            # fall back to --nobest if strict dep resolution fails.
            # CRB already enabled by __install_mail; re-enable idempotently in case
            # install order changes.
            dnf config-manager --set-enabled crb 2>/dev/null \
                || dnf config-manager --set-enabled powertools 2>/dev/null \
                || true
            $PACKAGE_MANAGER install -y libmemcached-awesome 2>/dev/null \
                || $PACKAGE_MANAGER install -y libmemcached 2>/dev/null || true
            $PACKAGE_MANAGER install -y proftpd proftpd-mysql \
                || $PACKAGE_MANAGER install -y --nobest proftpd proftpd-mysql \
                || warn "proftpd install failed — FTP may not be available"
            ;;
        "zypper")
            zypper install -y proftpd \
                || warn "proftpd install failed — FTP may not be available"
            ;;
    esac
    systemctl enable proftpd 2>/dev/null || true
    systemctl start  proftpd 2>/dev/null || true
}

# ── Additional tools ──────────────────────────────────────────────────────────
__try_install() {
    # Install packages, skipping any that are unavailable rather than aborting.
    local pm="$1"; shift
    for pkg in "$@"; do
        case "$pm" in
            apt)    apt-get install -y "$pkg" 2>/dev/null || warn "Package unavailable, skipping: $pkg" ;;
            dnf|yum) $pm install -y "$pkg" 2>/dev/null  || warn "Package unavailable, skipping: $pkg" ;;
            zypper) zypper install -y "$pkg" 2>/dev/null || warn "Package unavailable, skipping: $pkg" ;;
        esac
    done
}

__install_tools() {
    log "Installing additional tools..."
    case "$PACKAGE_MANAGER" in
        "apt")
            # Core tools
            apt-get install -y bind9 bind9utils rsync cron
            # quota requires kernel quota support — unavailable in most containers
            __try_install apt quota
            # certbot may be absent from trixie main (available via snap/pip)
            __try_install apt certbot
            # Optional / may be absent in newer distros
            __try_install apt awstats webalizer clamav clamav-daemon amavisd-new spamassassin
            ;;
        "dnf"|"yum")
            $PACKAGE_MANAGER install -y bind bind-utils rsync crontabs
            # RHEL named.conf includes named.conf.local which must exist before start
            touch /etc/named.conf.local
            __try_install "$PACKAGE_MANAGER" quota certbot
            __try_install "$PACKAGE_MANAGER" awstats webalizer clamav clamav-update amavisd-new spamassassin
            ;;
        "zypper")
            zypper install -y bind bind-utils rsync cron
            __try_install zypper quota awstats webalizer clamav amavisd-new spamassassin
            ;;
    esac
}

# ── fail2ban install + jails ──────────────────────────────────────────────────
__install_fail2ban() {
    log "Installing fail2ban..."
    case "$PACKAGE_MANAGER" in
        "apt")
            apt-get install -y fail2ban
            # python3-systemd is required for the systemd journal backend
            apt-get install -y python3-systemd 2>/dev/null || true
            ;;
        "dnf"|"yum")
            $PACKAGE_MANAGER install -y fail2ban
            $PACKAGE_MANAGER install -y python3-systemd 2>/dev/null || true
            ;;
        "zypper")
            zypper install -y fail2ban
            zypper install -y python3-systemd 2>/dev/null || true
            ;;
    esac

    # Write a single jail file covering all ISPConfig services.
    # All service jails use backend=systemd so fail2ban reads the journal
    # directly — no log files need to exist at startup. This works across
    # all supported distros (all use systemd) including those that do not
    # install rsyslog (Debian 12+, Ubuntu 22.04+, RHEL 9+).
    # ignoreip includes loopback so nginx→apache backend traffic is never banned.
    cat > /etc/fail2ban/jail.d/ispconfig.conf << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
backend  = systemd

[sshd]
enabled  = true
port     = ssh

[postfix]
enabled  = true
port     = smtp,465,587

[postfix-sasl]
enabled  = true
port     = smtp,465,587,imap,imaps,pop3,pop3s

[dovecot]
enabled  = true
port     = imap,imaps,pop3,pop3s,sieve

[proftpd]
enabled  = true
port     = ftp,ftp-data,ftps,ftps-data
# ProFTPd logs to a file; override the global systemd backend
logpath  = /var/log/proftpd/proftpd.log
backend  = auto

[ispconfig-panel]
enabled  = true
port     = ${ADMIN_PORT}
logpath  = /var/log/ispconfig/auth.log
backend  = auto
maxretry = 5
filter   = ispconfig-panel
EOF

    # Custom filter for ISPConfig panel login failures
    cat > /etc/fail2ban/filter.d/ispconfig-panel.conf << 'FILTER_EOF'
[Definition]
failregex = ^.*\[client <HOST>\].*authentication failure.*$
            ^.*Login failed for.*from <HOST>.*$
ignoreregex =
FILTER_EOF

    # ISPConfig creates /var/log/ispconfig after install; pre-create so fail2ban
    # can watch it immediately without errors on first start.
    mkdir -p /var/log/ispconfig
    touch /var/log/ispconfig/auth.log

    systemctl enable fail2ban
    systemctl restart fail2ban
    log "fail2ban installed and configured"
}

# ── ISPConfig install ─────────────────────────────────────────────────────────
__install_ispconfig() {
    log "Downloading ISPConfig..."
    cd /tmp
    wget -O ispconfig.tar.gz https://www.ispconfig.org/downloads/ISPConfig-3-stable.tar.gz
    tar xfz ispconfig.tar.gz
    cd ispconfig3*/install/

    log "Running ISPConfig autoinstall..."

    # ISPConfig uses INI-format autoinstall files (see docs/autoinstall_samples/)
    # ispconfig_port here is the *internal* Apache port (nginx proxies ADMIN_PORT → this)
    cat > /tmp/ispconfig_autoinstall.ini << EOF
[install]
language=en
install_mode=expert
hostname=${HOSTNAME}
mysql_hostname=localhost
mysql_port=3306
mysql_root_user=root
mysql_root_password=${MYSQL_ROOT_PASSWORD}
mysql_database=dbispconfig
mysql_charset=utf8mb4
http_server=apache
ispconfig_port=${APACHE_ADMIN_PORT}
ispconfig_use_ssl=n
ispconfig_admin_password=${ISPCONFIG_ADMIN_PASSWORD}
create_ssl_server_certs=n
ignore_hostname_dns=y
ispconfig_postfix_ssl_symlink=y
ispconfig_pureftpd_ssl_symlink=n

[ssl_cert]
ssl_cert_country=US
ssl_cert_state=.
ssl_cert_locality=.
ssl_cert_organisation=ISPConfig
ssl_cert_organisation_unit=.
ssl_cert_common_name=${HOSTNAME}
ssl_cert_email=admin@${HOSTNAME}

[expert]
mysql_ispconfig_user=ispconfig
mysql_ispconfig_password=${ISPCONFIG_DB_PASSWORD}
join_multiserver_setup=n
configure_mail=y
configure_jailkit=y
configure_ftp=y
configure_dns=y
configure_apache=y
configure_nginx=n
configure_firewall=n
install_ispconfig_web_interface=y
EOF

    # Locate PHP binary — prefer the system default, fall back to any installed version
    local php_bin
    php_bin=$(command -v php 2>/dev/null)
    if [[ -z "$php_bin" ]]; then
        php_bin=$(ls /usr/bin/php[0-9]* /usr/local/bin/php[0-9]* 2>/dev/null | grep -v cgi | sort -V | tail -1)
    fi
    if [[ -z "$php_bin" ]]; then
        error "No PHP binary found — PHP installation must have failed. Check logs above."
    fi
    log "Using PHP: $(${php_bin} -r 'echo PHP_VERSION;' 2>/dev/null)"

    ${php_bin} install.php --autoinstall=/tmp/ispconfig_autoinstall.ini
    rm -f /tmp/ispconfig_autoinstall.ini
}

# ── Apache backend hardening (runs after ISPConfig install) ──────────────────
__configure_apache_backend() {
    log "Reconfiguring Apache as reverse-proxy backend..."

    case "$DISTRO" in
        "ubuntu"|"debian")
            # Switch to Event MPM
            a2dismod mpm_prefork mpm_worker 2>/dev/null || true
            a2enmod  mpm_event remoteip

            # Tune Event MPM
            cat > /etc/apache2/mods-available/mpm_event.conf << 'MPMEOF'
<IfModule mpm_event_module>
    StartServers              4
    MinSpareThreads          25
    MaxSpareThreads          75
    ThreadLimit              64
    ThreadsPerChild          25
    MaxRequestWorkers       400
    MaxConnectionsPerChild 10000
</IfModule>
MPMEOF

            # Bind to loopback only on backend ports
            cat > /etc/apache2/ports.conf << PORTSEOF
Listen ${APACHE_BACKEND_IP}:${APACHE_BACKEND_PORT}
Listen ${APACHE_BACKEND_IP}:${APACHE_ADMIN_PORT}
Listen ${APACHE_BACKEND_IP}:${APACHE_APPS_PORT}
PORTSEOF

            # RemoteIP — trust nginx at 127.0.0.1
            cat > /etc/apache2/conf-available/remoteip.conf << 'RIPEOF'
RemoteIPHeader X-Forwarded-For
RemoteIPInternalProxy 127.0.0.1
RemoteIPInternalProxy ::1
RIPEOF
            a2enconf remoteip

            # HTTPS env passthrough from nginx X-Forwarded-Proto header
            cat > /etc/apache2/conf-available/forwarded-https.conf << 'FWDEOF'
SetEnvIf X-Forwarded-Proto https HTTPS=on
SetEnvIf X-Forwarded-Proto https REQUEST_SCHEME=https
FWDEOF
            a2enconf forwarded-https

            # Patch all Apache vhosts (ISPConfig uses both .conf and .vhost extensions)
            for dir in /etc/apache2/sites-available /etc/apache2/sites-enabled; do
                for f in "${dir}"/*.conf "${dir}"/*.vhost; do
                    [[ -f "$f" ]] || continue
                    sed -i \
                        -e "s|<VirtualHost \*:80>|<VirtualHost ${APACHE_BACKEND_IP}:${APACHE_BACKEND_PORT}>|g" \
                        -e "s|<VirtualHost \*:443>|<VirtualHost ${APACHE_BACKEND_IP}:${APACHE_BACKEND_PORT}>|g" \
                        -e "s|<VirtualHost \*:${ADMIN_PORT}>|<VirtualHost ${APACHE_BACKEND_IP}:${APACHE_ADMIN_PORT}>|g" \
                        -e "s|<VirtualHost _default_:\([0-9]*\)>|<VirtualHost ${APACHE_BACKEND_IP}:\1>|g" \
                        -e '/^[[:space:]]*Listen [0-9]/d' \
                        -e '/^[[:space:]]*NameVirtualHost/d' \
                        -e '/SSLEngine [Oo]n/d' \
                        -e '/SSLCertificateFile/d' \
                        -e '/SSLCertificateKeyFile/d' \
                        -e '/SSLCertificateChainFile/d' \
                        -e '/SSLCACertificateFile/d' \
                        -e '/SSLProtocol/d' \
                        -e '/SSLCipherSuite/d' \
                        -e '/SSLHonorCipherOrder/d' \
                        "$f"
                done
            done
            # Fix ISPConfig panel PHP-FCGI starters: point to actual installed PHP-CGI
            # ISPConfig may generate starters referencing a PHP version that isn't installed
            local php_cgi_bin
            php_cgi_bin=$(update-alternatives --query php-cgi 2>/dev/null | awk '/^Value:/{print $2}')
            [[ -z "$php_cgi_bin" ]] && php_cgi_bin=$(command -v "php-cgi${PHP_DEFAULT}" || command -v php-cgi 2>/dev/null)
            if [[ -n "$php_cgi_bin" ]]; then
                local php_ver_dir
                php_ver_dir=$(dirname "$(readlink -f "$php_cgi_bin")" 2>/dev/null | sed 's|/bin$||')
                # Extract version from binary name (php-cgi does not support -r; use path parsing)
                local php_ver
                php_ver=$(basename "$php_cgi_bin" | grep -oE '[0-9]+\.[0-9]+' | head -1)
                # Fallback: ask the CLI binary if path parsing yields nothing
                [[ -z "$php_ver" ]] && php_ver=$(command -v "php${PHP_DEFAULT}" >/dev/null 2>&1 && \
                    "php${PHP_DEFAULT}" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null) || true
                for starter in /var/www/php-fcgi-scripts/ispconfig/.php-fcgi-starter \
                               /var/www/php-fcgi-scripts/apps/.php-fcgi-starter; do
                    [[ -f "$starter" ]] || continue
                    sed -i \
                        -e "s|PHPRC=.*|PHPRC=/etc/php/${php_ver}/cgi/|" \
                        -e "s|exec /usr/bin/php-cgi|exec ${php_cgi_bin}|" \
                        "$starter"
                done
            fi
            systemctl restart apache2
            ;;

        *)  # RHEL-family and openSUSE
            # Switch to Event MPM
            if [[ -f /etc/httpd/conf.modules.d/00-mpm.conf ]]; then
                cat > /etc/httpd/conf.modules.d/00-mpm.conf << 'MPMEOF'
# LoadModule mpm_prefork_module modules/mod_mpm_prefork.so
# LoadModule mpm_worker_module  modules/mod_mpm_worker.so
LoadModule mpm_event_module   modules/mod_mpm_event.so
MPMEOF
            fi

            # ISPConfig writes its panel port from autoinstall.ini (ispconfig_port)
            # but the apps port is hardcoded by ISPConfig (panel_port is NOT +1).
            # Discover actual ports from the generated vhost files so we listen on
            # the right ports regardless of ISPConfig version defaults.
            local ispc_admin_port ispc_apps_port
            ispc_admin_port=$(grep -h "^[[:space:]]*Listen[[:space:]]" \
                "${APACHE_CONF_DIR}/conf/sites-available/ispconfig.vhost" 2>/dev/null | \
                awk '{print $2}' | head -1)
            ispc_apps_port=$(grep -h "^[[:space:]]*Listen[[:space:]]" \
                "${APACHE_CONF_DIR}/conf/sites-available/apps.vhost" 2>/dev/null | \
                awk '{print $2}' | head -1)
            [[ -n "$ispc_admin_port" ]] && APACHE_ADMIN_PORT="$ispc_admin_port"
            [[ -n "$ispc_apps_port"  ]] && APACHE_APPS_PORT="$ispc_apps_port"
            log "ISPConfig panel port: ${APACHE_ADMIN_PORT}, apps port: ${APACHE_APPS_PORT}"

            # Replace ALL Listen directives in httpd.conf with our loopback-only set.
            # ISPConfig's vhost files also carry their own Listen lines which we
            # will strip below — this leaves httpd.conf as the single authority.
            sed -i '/^[[:space:]]*Listen /d' "${APACHE_CONF_DIR}/conf/httpd.conf"
            cat >> "${APACHE_CONF_DIR}/conf/httpd.conf" << LISTENEOF

# Backend ports — loopback only (nginx terminates TLS externally)
Listen ${APACHE_BACKEND_IP}:${APACHE_BACKEND_PORT}
Listen ${APACHE_BACKEND_IP}:${APACHE_ADMIN_PORT}
Listen ${APACHE_BACKEND_IP}:${APACHE_APPS_PORT}
LISTENEOF

            # Event MPM tuning
            cat >> "${APACHE_CONF_DIR}/conf/httpd.conf" << 'MPMTUNEEOF'

<IfModule mpm_event_module>
    StartServers              4
    MinSpareThreads          25
    MaxSpareThreads          75
    ThreadLimit              64
    ThreadsPerChild          25
    MaxRequestWorkers       400
    MaxConnectionsPerChild 10000
</IfModule>
MPMTUNEEOF

            # RemoteIP + HTTPS passthrough (mod_remoteip is in the base httpd package)
            cat > "${APACHE_CONF_EXTRA}/remoteip.conf" << 'RIPEOF'
RemoteIPHeader X-Forwarded-For
RemoteIPInternalProxy 127.0.0.1
RemoteIPInternalProxy ::1
SetEnvIf X-Forwarded-Proto https HTTPS=on
SetEnvIf X-Forwarded-Proto https REQUEST_SCHEME=https
RIPEOF

            # Patch ALL vhost files:
            #   - Standard conf.d (PHP, fcgid, etc.)
            #   - ISPConfig's sites-available and sites-enabled directories
            # Strategy: keep port numbers but restrict to loopback IP; strip
            # Listen/NameVirtualHost lines (httpd.conf is now the single listener authority).
            for vhost_dir in "${APACHE_VHOST_DIR}" \
                             "${APACHE_CONF_DIR}/conf/sites-available" \
                             "${APACHE_CONF_DIR}/conf/sites-enabled"; do
                [[ -d "$vhost_dir" ]] || continue
                for f in "${vhost_dir}"/*.conf "${vhost_dir}"/*.vhost; do
                    [[ -f "$f" ]] || continue
                    sed -i \
                        -e "s|<VirtualHost \*:\([0-9]*\)>|<VirtualHost ${APACHE_BACKEND_IP}:\1>|g" \
                        -e "s|<VirtualHost _default_:\([0-9]*\)>|<VirtualHost ${APACHE_BACKEND_IP}:\1>|g" \
                        -e '/^[[:space:]]*Listen /d' \
                        -e '/^[[:space:]]*NameVirtualHost/d' \
                        -e '/SSLEngine [Oo]n/d' \
                        -e '/SSLCertificateFile/d' \
                        -e '/SSLCertificateKeyFile/d' \
                        -e '/SSLCertificateChainFile/d' \
                        -e '/SSLCACertificateFile/d' \
                        -e '/SSLProtocol/d' \
                        -e '/SSLCipherSuite/d' \
                        -e '/SSLHonorCipherOrder/d' \
                        "$f"
                done
            done
            systemctl restart "${APACHE_SERVICE}"
            ;;
    esac

    success "Apache reconfigured: backend on ${APACHE_BACKEND_IP}:${APACHE_BACKEND_PORT} / admin on ${APACHE_BACKEND_IP}:${APACHE_ADMIN_PORT}"
}

# ── ISPConfig + Nginx wiring ──────────────────────────────────────────────────
__configure_ispconfig_nginx() {
    log "Wiring ISPConfig to Nginx reverse proxy..."

    local ISPC_CONF="/usr/local/ispconfig/server/conf"
    local ISPC_CONF_CUSTOM="/usr/local/ispconfig/server/conf-custom"
    mkdir -p "$ISPC_CONF_CUSTOM"

    # Patch ISPConfig vhost templates so newly-created sites land on the backend port
    if [[ -d "$ISPC_CONF" ]]; then
        for tpl in "$ISPC_CONF"/*.master; do
            [[ -f "$tpl" ]] || continue
            sed -i \
                -e "s/<VirtualHost \*:80>/<VirtualHost ${APACHE_BACKEND_IP}:${APACHE_BACKEND_PORT}>/g" \
                -e "s/<VirtualHost \*:443>/<VirtualHost ${APACHE_BACKEND_IP}:${APACHE_BACKEND_PORT}>/g" \
                -e "s/<VirtualHost {ip}:80>/<VirtualHost ${APACHE_BACKEND_IP}:${APACHE_BACKEND_PORT}>/g" \
                -e "s/<VirtualHost {ip}:443>/<VirtualHost ${APACHE_BACKEND_IP}:${APACHE_BACKEND_PORT}>/g" \
                -e '/SSLEngine on/d' \
                -e '/SSLCertificateFile/d' \
                -e '/SSLCertificateKeyFile/d' \
                -e '/SSLCertificateChainFile/d' \
                "$tpl"
        done
        log "ISPConfig Apache templates patched"
    fi

    # nginx vhost for ISPConfig admin panel (port ADMIN_PORT → Apache admin port)
    cat > "${NGINX_VHOSTS_DIR}/ispconfig-panel.conf" << VHOST_EOF
server {
    listen      ${ADMIN_PORT} ssl http2;
    listen      [::]:${ADMIN_PORT} ssl http2;
    server_name _;

    ssl_certificate     ${SSL_DIR}/ispconfig.crt;
    ssl_certificate_key ${SSL_DIR}/ispconfig.key;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;

    location / {
        proxy_pass http://ispconfig_admin;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port ${ADMIN_PORT};
    }
}
VHOST_EOF

    # Install nginx-sync helper — regenerates per-domain nginx vhosts from ISPConfig certs
    cat > /usr/local/bin/ispconfig-nginx-sync << 'SYNCEOF'
#!/bin/bash
# Syncs nginx SSL vhosts with ISPConfig Let's Encrypt certificates.
# Run after certbot renewal: add to /etc/letsencrypt/renewal-hooks/deploy/
VHOSTS_DIR="/etc/nginx/vhosts.d"
APACHE_BACKEND="127.0.0.1:81"
changed=0

for cert_dir in /etc/letsencrypt/live/*/; do
    domain=$(basename "$cert_dir")
    vhost_file="${VHOSTS_DIR}/${domain}.conf"
    fullchain="${cert_dir}fullchain.pem"
    privkey="${cert_dir}privkey.pem"

    [[ -f "$fullchain" && -f "$privkey" ]] || continue

    new_content="server {
    listen      443 ssl http2;
    listen      [::]:443 ssl http2;
    server_name ${domain} www.${domain};

    ssl_certificate     ${fullchain};
    ssl_certificate_key ${privkey};

    add_header Strict-Transport-Security \"max-age=31536000; includeSubDomains\" always;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        proxy_pass http://${APACHE_BACKEND};
    }
}"

    existing_content=""
    [[ -f "$vhost_file" ]] && existing_content=$(cat "$vhost_file")
    if [[ "$new_content" != "$existing_content" ]]; then
        echo "$new_content" > "$vhost_file"
        changed=1
    fi
done

if [[ $changed -eq 1 ]]; then
    nginx -t && systemctl reload nginx
fi
SYNCEOF
    chmod +x /usr/local/bin/ispconfig-nginx-sync

    # Hook into certbot renewal
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    ln -sf /usr/local/bin/ispconfig-nginx-sync \
        /etc/letsencrypt/renewal-hooks/deploy/99-ispconfig-nginx-sync

    log "nginx-sync helper installed at /usr/local/bin/ispconfig-nginx-sync"
}

# ── SSL / certs ───────────────────────────────────────────────────────────────
__configure_ssl() {
    log "Generating SSL assets for Nginx..."
    mkdir -p "$SSL_DIR"

    log "Generating DH parameters (2048-bit, takes ~30s)..."
    openssl dhparam -out /etc/nginx/dhparam.pem 2048

    # Default nginx catch-all cert
    if [[ ! -f "${SSL_DIR}/default.crt" ]]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "${SSL_DIR}/default.key" \
            -out    "${SSL_DIR}/default.crt" \
            -subj   "/C=US/ST=./L=./O=Default/CN=${HOSTNAME}"
    fi

    # ISPConfig admin panel cert (nginx uses this for :ADMIN_PORT listener)
    if [[ ! -f "${SSL_DIR}/ispconfig.crt" ]]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "${SSL_DIR}/ispconfig.key" \
            -out    "${SSL_DIR}/ispconfig.crt" \
            -subj   "/C=US/ST=./L=./O=ISPConfig/CN=${HOSTNAME}"
    fi

    # If ISPConfig generated its own cert, keep a copy for reference
    if [[ -f /usr/local/ispconfig/interface/ssl/ispserver.crt ]]; then
        cp /usr/local/ispconfig/interface/ssl/ispserver.crt "${SSL_DIR}/ispconfig-original.crt" 2>/dev/null || true
    fi

    chmod 640 "${SSL_DIR}"/*.key 2>/dev/null || true
    success "SSL assets generated in ${SSL_DIR}"
}

# ── Final configuration ───────────────────────────────────────────────────────
__final_configuration() {
    log "Performing final configuration..."

    # Log rotation for ISPConfig
    cat > /etc/logrotate.d/ispconfig << 'EOF'
/var/log/ispconfig/*.log {
    weekly
    missingok
    rotate 52
    compress
    delaycompress
    notifempty
    create 644 root root
}
EOF

    # Restart order matters: Apache first (nginx needs backend up)
    case "$DISTRO" in
        "ubuntu"|"debian")
            systemctl restart apache2
            for v in "${PHP_VERSIONS[@]}"; do
                systemctl restart php${v}-fpm 2>/dev/null || true
            done
            ;;
        *)
            systemctl restart "${APACHE_SERVICE}"
            for v in "${PHP_VERSIONS[@]}"; do
                local vc=${v//./}
                systemctl restart php${vc}-php-fpm 2>/dev/null || true
            done
            ;;
    esac

    systemctl restart postfix dovecot proftpd 2>/dev/null || true
    nginx -t && systemctl start nginx

    # Sync any existing Let's Encrypt certs into Nginx vhosts (no-op on fresh installs)
    if [[ -d /etc/letsencrypt/live ]]; then
        /usr/local/bin/ispconfig-nginx-sync 2>/dev/null || true
    fi

    __create_php_test_script
}

__create_php_test_script() {
    local web_root="/var/www/html"
    [[ "$DISTRO" =~ ^(opensuse|sles) ]] && web_root="/srv/www/htdocs"

    cat > "${web_root}/phpinfo.php" << 'EOF'
<?php
$versions = [];
foreach (glob('/usr/bin/php*') as $bin) {
    if (preg_match('/php(\d+\.\d+)$/', $bin, $m)) $versions[$m[1]] = $bin;
}
foreach (glob('/opt/remi/php*/root/usr/bin/php') as $bin) {
    if (preg_match('/php(\d+)/', $bin, $m)) {
        $v = substr($m[1],0,1).'.'.substr($m[1],1);
        $versions[$v] = $bin;
    }
}
ksort($versions);
echo "<h1>PHP Versions</h1><ul>";
foreach ($versions as $v => $p) echo "<li><strong>PHP $v</strong>: $p</li>";
echo "</ul>";
echo "<p>X-Forwarded-Proto: " . htmlspecialchars($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? 'not set') . "</p>";
echo "<p>HTTPS: " . htmlspecialchars($_SERVER['HTTPS'] ?? 'off') . "</p>";
phpinfo();
EOF

    chown "${NGINX_USER}:${NGINX_USER}" "${web_root}/phpinfo.php" 2>/dev/null || true
    chmod 644 "${web_root}/phpinfo.php"
}

# ── Summary ───────────────────────────────────────────────────────────────────
__create_summary() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    cat > /root/ispconfig_installation_summary.txt << EOF
ISPConfig Installation Summary — Nginx Reverse Proxy Architecture
=================================================================
Date:         $(date)
Distribution: ${DISTRO} ${DISTRO_VERSION}
Hostname:     ${HOSTNAME}
Server IP:    ${server_ip}

Architecture:
  Nginx  :80             → HTTP to HTTPS redirect
  Nginx  :443            → SSL termination → Apache ${APACHE_BACKEND_IP}:${APACHE_BACKEND_PORT}
  Nginx  :${ADMIN_PORT}          → SSL termination → Apache ${APACHE_BACKEND_IP}:${APACHE_ADMIN_PORT}
  Apache ${APACHE_BACKEND_IP}:${APACHE_BACKEND_PORT} → PHP-FPM, .htaccess, ISPConfig sites
  Apache ${APACHE_BACKEND_IP}:${APACHE_ADMIN_PORT}   → ISPConfig control panel

Credentials:
  ISPConfig panel:    https://${server_ip}:${ADMIN_PORT}
  ISPConfig username: admin
  ISPConfig password: ${ISPCONFIG_ADMIN_PASSWORD}

  MySQL root user:    root
  MySQL root pass:    ${MYSQL_ROOT_PASSWORD}

  ISPConfig DB user:  ispconfig
  ISPConfig DB pass:  ${ISPCONFIG_DB_PASSWORD}

SSL certificates (self-signed, replace with Let's Encrypt):
  Default:    ${SSL_DIR}/default.{crt,key}
  ISPConfig:  ${SSL_DIR}/ispconfig.{crt,key}
  Mail TLS:   /usr/local/ispconfig/interface/ssl/ispserver.{crt,key}
  DH params:  /etc/nginx/dhparam.pem

Mail server ports (ensure these are open in your firewall/cloud panel):
  25   — SMTP (inbound from internet, MX delivery)
  465  — SMTPS (authenticated submission, TLS wrapper)
  587  — Submission (authenticated submission, STARTTLS)
  143  — IMAP (STARTTLS)
  993  — IMAPS (TLS)
  110  — POP3 (STARTTLS)
  995  — POP3S (TLS)

DKIM (required for reliable delivery to Gmail, Yahoo, Outlook):
  1. In ISPConfig: DNS → Zones → select domain → DKIM
     Generate a key, copy the TXT record value
  2. Add to your DNS:
       mail._domainkey.yourdomain.com  TXT  "v=DKIM1; k=rsa; p=<key>"
  3. Add SPF record:
       yourdomain.com  TXT  "v=spf1 a mx ip4:${server_ip} ~all"
  4. Add DMARC record:
       _dmarc.yourdomain.com  TXT  "v=DMARC1; p=quarantine; rua=mailto:admin@yourdomain.com"
  5. Set PTR (reverse DNS) for ${server_ip} → ${HOSTNAME} with your VPS provider

Nginx vhosts drop-in dir: ${NGINX_VHOSTS_DIR}/
  Drop *.conf files here for custom apps (node, ruby, go, etc.)
  Run: nginx -t && systemctl reload nginx

Let's Encrypt:
  ACME webroot: ${LETSENCRYPT_WEBROOT}
  After cert issue, run: /usr/local/bin/ispconfig-nginx-sync
  Auto-runs on certbot renewal via deploy hook.

Important files:
  /usr/local/ispconfig/          ISPConfig root
  /etc/nginx/nginx.conf          Nginx config
  ${NGINX_VHOSTS_DIR}/           Nginx virtual hosts
  ${APACHE_CONF_DIR}/            Apache config
  /etc/postfix/main.cf           Postfix config
  /etc/dovecot/conf.d/           Dovecot config
  /etc/opendkim.conf             OpenDKIM config
  /root/.my.cnf                  MySQL root credentials

Next steps:
  1. Log in: https://${server_ip}:${ADMIN_PORT}
  2. Replace self-signed certs with Let's Encrypt
  3. Run ispconfig-nginx-sync after first cert issuance
  4. Configure DKIM/SPF/DMARC DNS records (see above)
  5. Set reverse DNS (PTR) for your server IP with your VPS provider
  6. Drop custom app vhosts in ${NGINX_VHOSTS_DIR}/
  7. Remove /var/www/html/phpinfo.php before going live
EOF

    log "Summary saved to /root/ispconfig_installation_summary.txt"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo -e "${PURPLE}"
    echo "============================================"
    echo "  ISPConfig — Nginx Reverse Proxy Installer"
    echo "============================================"
    echo -e "${NC}"

    __check_root
    __detect_distro
    __generate_passwords
    __set_hostname

    __update_system
    __install_base_packages
    __configure_firewall

    __install_nginx
    __install_apache
    __install_mysql
    __install_php
    __install_mail
    __install_ftp
    __install_tools
    __install_fail2ban

    __install_ispconfig

    __configure_apache_backend
    __configure_ispconfig_nginx
    __configure_mail_public
    __configure_ssl

    __final_configuration
    __create_summary

    echo -e "${GREEN}"
    log "============================================"
    log "Installation complete!"
    log "============================================"
    echo -e "${NC}"
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
    log "ISPConfig panel:    https://${server_ip}:${ADMIN_PORT}"
    log "ISPConfig username: admin"
    log "ISPConfig password: ${ISPCONFIG_ADMIN_PASSWORD}"
    log "MySQL root user:    root"
    log "MySQL root pass:    ${MYSQL_ROOT_PASSWORD}"
    log "ISPConfig DB user:  ispconfig"
    log "ISPConfig DB pass:  ${ISPCONFIG_DB_PASSWORD}"
    warn "Credentials saved to: /root/ispconfig_installation_summary.txt"
    echo -e "${NC}"
}

main "$@"
