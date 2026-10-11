#!/bin/bash
# shellcheck shell=bash
# - - - - - - - - - - - - - - - - - - - - - - - - -
##@Version           :  202610111745-git
# @@Author           :  ISPConfig Universal Installer Contributors
# @@Contact          :  https://github.com/scriptmgr/ispconfig
# @@License          :  MIT
# @@ReadME           :  README.md
# @@Copyright        :  Copyright: (c) 2025 ISPConfig Universal Installer Contributors
# @@Created          :  Monday, August 24, 2026 15:34 EDT
# @@File             :  install.sh
# @@Description      :  Universal distro-agnostic ISPConfig installer with Apache direct hosting, multi-PHP, and full mail stack
# @@Changelog        :  See git log for full history; latest: 404 catch-all page for unconfigured hosts, env credential overrides, DNS enable on boot
# @@TODO             :  none
# @@Other            :  none
# @@Resource         :  https://www.ispconfig.org/
# @@Terminal App     :  yes
# @@sudo/root        :  yes
# @@Template         :  shell/bash
# - - - - - - - - - - - - - - - - - - - - - - - - -
# shellcheck disable=SC1001,SC1003,SC2001,SC2003,SC2016,SC2031,SC2090,SC2115,SC2120,SC2155,SC2199,SC2229,SC2317,SC2329
# - - - - - - - - - - - - - - - - - - - - - - - - -
VERSION="202610111745-git"

# Universal ISPConfig Installation Script
# Architecture: Apache direct listeners on :80/:443; ISPConfig panel on configured hostname
# Run as root: bash install.sh

set -e

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'
CLR_EOL='\033[K'

# ── Global variables ──────────────────────────────────────────────────────────
# Package scripts must never prompt (postfix, tzdata, needrestart, ...). Set
# globally: __step runs each phase in a subshell, so an export made inside one
# step would not reach the next.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none

# __step runs each phase in a subshell, so variables a phase discovers at
# runtime (PHP_DEFAULT, Apache ports) are written here with __save_var and
# re-read by __step after the phase succeeds.
STATE_FILE=""
NOSITE_PHPINFO=0

ADMIN_PORT=443
ISPCONFIG_MYSQL_ROOT_PASSWORD="${ISPCONFIG_MYSQL_ROOT_PASSWORD:-}"
ISPCONFIG_ADMIN_PASSWORD="${ISPCONFIG_ADMIN_PASSWORD:-}"
ISPCONFIG_ADMIN_USER="${ISPCONFIG_ADMIN_USER:-}"
ISPCONFIG_DB_PASSWORD="${ISPCONFIG_DB_PASSWORD:-}"
HOSTNAME=""
DISTRO=""
DISTRO_VERSION=""
PACKAGE_MANAGER=""
SERVICE_MANAGER="systemctl"
# fallback; overwritten after install to highest available version
PHP_DEFAULT="8.3"
PHP_VERSIONS=("8.5" "8.4" "8.3" "8.2" "8.1" "8.0" "7.4")

# Apache direct-listener settings
APACHE_BACKEND_IP="127.0.0.1"
APACHE_ADMIN_PORT="7080"
APACHE_APPS_PORT="7081"
PANEL_HOSTNAME="${ISPCONFIG_PANEL_HOSTNAME:-panel.casjay.app}"
LETSENCRYPT_WEBROOT="/var/www/letsencrypt"
SSL_DIR="/etc/ssl/ispconfig"
PANEL_CERT_FILE="${ISPCONFIG_PANEL_CERT:-/etc/ssl/ispconfig/ispconfig.crt}"
PANEL_KEY_FILE="${ISPCONFIG_PANEL_KEY:-/etc/ssl/ispconfig/ispconfig.key}"

# Set by __validate_distro
APACHE_USER=""
SSL_CA_BUNDLE=""
APACHE_SERVICE=""
APACHE_CONF_DIR=""
APACHE_VHOST_DIR=""
APACHE_CONF_EXTRA=""

# ── Logging ───────────────────────────────────────────────────────────────────
__log()     { echo -e "${GREEN}[INFO]${NC} $1"; }
__warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
__error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
__success() { echo -e "${BLUE}[SUCCESS]${NC} $1"; }

# Prints the failure marker plus the tail of a captured step log, then exits.
# Used by __step on a non-zero exit so package-manager noise stays hidden on
# success and only surfaces when something actually breaks.
__failed() {
    local desc="$1" logfile="$2" rc="${3:-1}"
    printf "\r%s ${RED}[FAILED]${NC}${CLR_EOL}\n" "$desc"
    if [[ -n "$logfile" && -s "$logfile" ]]; then
        echo -e "${RED}--- last 40 lines of output (${logfile}) ---${NC}"
        tail -n 40 "$logfile"
    fi
    exit "$rc"
}

# Simple ASCII spinner; runs as a background job and is killed by __step.
__spin() {
    local desc="$1" frames='|/-\' i=0
    while :; do
        i=$(( (i + 1) % 4 ))
        printf "\r%s %s${CLR_EOL}" "$desc" "${frames:$i:1}"
        sleep 0.2
    done
}

# Runs a function quietly: stdout/stderr are captured to a temp log instead
# of streaming to the terminal, a spinner shows progress, and the result
# collapses to one line — "[OK]" on success, or __failed's report on failure.
__save_var() {
    [[ -n "$STATE_FILE" ]] && printf '%s=%q\n' "$1" "${!1}" >> "$STATE_FILE"
    return 0
}

__step() {
    local desc="$1"; shift
    local logfile spin_pid rc
    logfile=$(mktemp /tmp/ispconfig-install.XXXXXX.log)
    if [[ -t 1 ]]; then
        __spin "$desc" &
        spin_pid=$!
    fi
    trap 'ec=$?; [[ -n "${spin_pid:-}" ]] && kill "$spin_pid" 2>/dev/null; __failed "$desc" "$logfile" "$ec"' EXIT
    # The body must run in a subshell with set -e armed. Neither `if { "$@"; }`
    # nor `( "$@" ) && ... || ...` works: bash suspends set -e for everything
    # inside a condition or an and/or list, so a mid-function failure would be
    # discarded and only the last command's status would reach us. Run it as a
    # plain command with set -e set explicitly, and capture its status with
    # set +e around the call so this shell survives a failing step.
    set +e
    ( set -e; "$@" ) >"$logfile" 2>&1
    rc=$?
    set -e
    trap - EXIT
    if [[ -n "${spin_pid:-}" ]]; then
        kill "$spin_pid" 2>/dev/null || true
        wait "$spin_pid" 2>/dev/null || true
    fi
    if [[ $rc -eq 0 ]]; then
        # shellcheck disable=SC1090
        [[ -n "$STATE_FILE" && -s "$STATE_FILE" ]] && source "$STATE_FILE"
        printf "\r%s ${GREEN}[OK]${NC}${CLR_EOL}\n" "$desc"
        rm -f "$logfile"
    else
        __failed "$desc" "$logfile" "$rc"
    fi
}

# ── Root check ────────────────────────────────────────────────────────────────
__check_root() {
    if [[ $EUID -ne 0 ]]; then
        __error "This script must be run as root"
    fi
}

# __update_system runs a full system upgrade, which can restart sshd/systemd/
# dbus (directly, or via an auto-restart hook like needrestart) and kill the
# very SSH session running this script. Warn up front — non-blocking — when
# connected over SSH without a terminal multiplexer to survive that.
__check_session_safety() {
    if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" && -z "${TMUX:-}${STY:-}" ]]; then
        __warn "Running over SSH without tmux/screen. The system-update step can restart sshd/systemd and drop this session mid-install."
        __warn "Recommended: re-run inside 'tmux new -s ispconfig' or 'screen -S ispconfig'."
    fi
}

# A second run on an installed server would reset the MySQL root password and
# print new credentials while the ISPConfig DB user and panel admin keep the
# old ones, leaving the summary wrong. Refuse to run instead.
__check_existing_install() {
    [[ -f /usr/local/ispconfig/interface/lib/config.inc.php ]] || return 0
    if [[ -f /root/ispconfig_installation_summary.txt ]]; then
        __error "ISPConfig is already installed (/usr/local/ispconfig). This installer is for fresh servers only; \
existing credentials are in /root/ispconfig_installation_summary.txt"
    fi
    __error "A previous run installed ISPConfig (/usr/local/ispconfig) but did not finish, so no credentials were saved. \
Re-run on a fresh server, or remove /usr/local/ispconfig and drop the dbispconfig database first"
}

# ── Distro detection ──────────────────────────────────────────────────────────
__detect_distro() {
    __log "Detecting Linux distribution..."
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO="$ID"
        DISTRO_VERSION="$VERSION_ID"
    elif [[ -f /etc/debian_version ]]; then
        DISTRO="debian"
        DISTRO_VERSION=$(< /etc/debian_version)
    elif [[ -f /etc/redhat-release ]]; then
        grep -q -- "CentOS"    /etc/redhat-release && DISTRO="centos"
        grep -q -- "Red Hat"   /etc/redhat-release && DISTRO="rhel"
        grep -q -- "AlmaLinux" /etc/redhat-release && DISTRO="almalinux"
        grep -q -- "Rocky"     /etc/redhat-release && DISTRO="rocky"
        DISTRO_VERSION=$(grep -oE -- '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
    else
        __error "Cannot detect Linux distribution"
    fi
    __log "Detected: $DISTRO $DISTRO_VERSION"
    __validate_distro
}

__validate_distro() {
    local supported=false
    case "$DISTRO" in
        "ubuntu")
            [[ "$DISTRO_VERSION" =~ ^(18|20|22|24|25|26) ]] && supported=true && PACKAGE_MANAGER="apt"
            APACHE_USER="www-data"
            SSL_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
            APACHE_SERVICE="apache2"
            APACHE_CONF_DIR="/etc/apache2"
            APACHE_VHOST_DIR="/etc/apache2/sites-available"
            APACHE_CONF_EXTRA="/etc/apache2/conf-available"
            ;;
        "debian")
            [[ "$DISTRO_VERSION" =~ ^(9|10|11|12|13) ]] && supported=true && PACKAGE_MANAGER="apt"
            APACHE_USER="www-data"
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
            APACHE_USER="apache"
            SSL_CA_BUNDLE="/etc/pki/tls/certs/ca-bundle.crt"
            APACHE_SERVICE="httpd"
            APACHE_CONF_DIR="/etc/httpd"
            APACHE_VHOST_DIR="/etc/httpd/conf.d"
            APACHE_CONF_EXTRA="/etc/httpd/conf.d"
            ;;
        "almalinux"|"rocky")
            [[ "$DISTRO_VERSION" =~ ^(8|9|10) ]] && supported=true && PACKAGE_MANAGER="dnf"
            APACHE_USER="apache"
            SSL_CA_BUNDLE="/etc/pki/tls/certs/ca-bundle.crt"
            APACHE_SERVICE="httpd"
            APACHE_CONF_DIR="/etc/httpd"
            APACHE_VHOST_DIR="/etc/httpd/conf.d"
            APACHE_CONF_EXTRA="/etc/httpd/conf.d"
            ;;
        "fedora")
            [[ "$DISTRO_VERSION" =~ ^(3[6-9]|4[0-9]) ]] && supported=true && PACKAGE_MANAGER="dnf"
            APACHE_USER="apache"
            SSL_CA_BUNDLE="/etc/pki/tls/certs/ca-bundle.crt"
            APACHE_SERVICE="httpd"
            APACHE_CONF_DIR="/etc/httpd"
            APACHE_VHOST_DIR="/etc/httpd/conf.d"
            APACHE_CONF_EXTRA="/etc/httpd/conf.d"
            ;;
        "opensuse"|"opensuse-leap"|"sles")
            [[ "$DISTRO_VERSION" =~ ^(15|42) ]] && supported=true && PACKAGE_MANAGER="zypper"
            APACHE_USER="apache"
            SSL_CA_BUNDLE="/etc/ssl/ca-bundle.pem"
            APACHE_SERVICE="apache2"
            APACHE_CONF_DIR="/etc/apache2"
            APACHE_VHOST_DIR="/etc/apache2/vhosts.d"
            APACHE_CONF_EXTRA="/etc/apache2/conf.d"
            ;;
    esac

    if [[ "$supported" != "true" ]]; then
        __error "Unsupported distribution: $DISTRO $DISTRO_VERSION
Supported: Ubuntu 18-26, Debian 9-13, CentOS/RHEL 7-9, AlmaLinux/Rocky 8-10, Fedora 36-49, openSUSE Leap 15.x"
    fi
    __success "Distribution $DISTRO $DISTRO_VERSION is supported (${PACKAGE_MANAGER})"
}

# ── Passwords ─────────────────────────────────────────────────────────────────
# Supplied credentials are embedded in SQL strings, PHP config and the
# ISPConfig answer file, so characters that would break any of those are
# rejected up front rather than corrupting the install halfway through.
__validate_credential() {
    local name="$1" value="$2"
    if [[ -n "$value" && "$value" =~ [\'\"\\\`\$[:space:]] ]]; then
        __error "${name} contains an unsupported character (quote, backslash, backtick, dollar sign or whitespace)"
    fi
}

__generate_passwords() {
    __validate_credential ISPCONFIG_MYSQL_ROOT_PASSWORD "$ISPCONFIG_MYSQL_ROOT_PASSWORD"
    __validate_credential ISPCONFIG_ADMIN_PASSWORD "$ISPCONFIG_ADMIN_PASSWORD"
    __validate_credential ISPCONFIG_DB_PASSWORD "$ISPCONFIG_DB_PASSWORD"
    if [[ -n "$ISPCONFIG_ADMIN_USER" && ! "$ISPCONFIG_ADMIN_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
        __error "ISPCONFIG_ADMIN_USER may contain only letters, digits, dot, underscore and hyphen"
    fi
    if [[ ! "$PANEL_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ \
        || ${#PANEL_HOSTNAME} -gt 253 ]]; then
        __error "ISPCONFIG_PANEL_HOSTNAME must be a valid fully-qualified DNS hostname"
    fi
    if [[ -n "${ISPCONFIG_PANEL_CERT:-}" && -z "${ISPCONFIG_PANEL_KEY:-}" \
        || -z "${ISPCONFIG_PANEL_CERT:-}" && -n "${ISPCONFIG_PANEL_KEY:-}" ]]; then
        __error "ISPCONFIG_PANEL_CERT and ISPCONFIG_PANEL_KEY must be set together"
    fi
    if [[ ! "$PANEL_CERT_FILE" =~ ^/[A-Za-z0-9._/-]+$ || ! "$PANEL_KEY_FILE" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
        __error "ISPCONFIG_PANEL_CERT and ISPCONFIG_PANEL_KEY must be absolute paths without whitespace"
    fi
    if [[ -z "$ISPCONFIG_MYSQL_ROOT_PASSWORD" ]]; then
        ISPCONFIG_MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)
        __log "Generated MySQL root password"
    fi
    if [[ -z "$ISPCONFIG_ADMIN_PASSWORD" ]]; then
        ISPCONFIG_ADMIN_PASSWORD=$(openssl rand -base64 32)
        __log "Generated ISPConfig admin password"
    fi
    # Not a secret to generate — ISPConfig's own autoinstall.ini has no key for
    # this (the installer always seeds the panel account as "admin"); default
    # here just preserves that behavior when the caller doesn't override it.
    ISPCONFIG_ADMIN_USER="${ISPCONFIG_ADMIN_USER:-admin}"
    if [[ -z "$ISPCONFIG_DB_PASSWORD" ]]; then
        ISPCONFIG_DB_PASSWORD=$(openssl rand -base64 32)
        __log "Generated ISPConfig DB user password"
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

    __log "Hostname configured: ${HOSTNAME}"
}

# ── System update ─────────────────────────────────────────────────────────────
__update_system() {
    __log "Updating system packages..."
    case "$PACKAGE_MANAGER" in
        "apt")
            export DEBIAN_FRONTEND=noninteractive
            # A previous upgrade or reboot can leave packages unpacked but not
            # configured; apt refuses to do anything until that is finished.
            dpkg --configure -a
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
    __log "Installing base packages..."
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

# ── Existing Nginx shutdown ───────────────────────────────────────────────────
__disable_nginx() {
    if ! command -v nginx >/dev/null 2>&1 && ! systemctl list-unit-files nginx.service --no-legend 2>/dev/null | grep -q -- '^nginx\.service'; then
        __log "Nginx is not installed"
        return 0
    fi

    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    systemctl mask nginx 2>/dev/null || true
    __log "Nginx stopped, disabled, and masked"
}

# ── Apache install ────────────────────────────────────────────────────────────
__install_apache() {
    __log "Installing Apache web server..."
    case "$PACKAGE_MANAGER" in
        "apt")
            apt-get install -y apache2 apache2-utils libapache2-mod-fcgid apache2-suexec-pristine
            a2enmod rewrite fcgid actions alias suexec
            systemctl enable apache2
            systemctl start apache2
            ;;
        "dnf"|"yum")
            $PACKAGE_MANAGER install -y httpd mod_ssl mod_fcgid
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
# A base image's pre-seeded MariaDB layout can stop the server from starting:
# /var/lib/mysql owned by root, a config mysqld cannot read, or ssl-key/ssl-cert
# paths pointing at root-only files. Repair what is safe to repair before the
# first start; the key keeps its mode and gains a read ACL for mysql only.
__prepare_mariadb() {
    getent passwd mysql >/dev/null 2>&1 || return 0

    install -d -o mysql -g mysql -m 0755 /var/lib/mysql
    local logdir
    for logdir in /var/log/mysql /var/log/mariadb; do
        [[ -d "$logdir" ]] && chown -R mysql:mysql "$logdir"
    done

    local cnf
    for cnf in /etc/my.cnf /etc/mysql/my.cnf; do
        [[ -f "$cnf" ]] || continue
        runuser -u mysql -- test -r "$cnf" 2>/dev/null && continue
        if command -v setfacl >/dev/null 2>&1 && setfacl -m u:mysql:r "$cnf"; then
            __warn "Granted the mysql user read access to ${cnf} with an ACL"
        else
            chgrp mysql "$cnf"
            chmod 0640 "$cnf"
            __warn "Changed ${cnf} to root:mysql mode 0640 for mysql access"
        fi
        runuser -u mysql -- test -r "$cnf" 2>/dev/null \
            || __error "The mysql user still cannot read ${cnf}"
    done

    # [client] ssl-key/ssl-cert apply to every libmysqlclient user: Postfix's
    # MySQL maps, amavisd, Dovecot, ISPConfig. When they point at a file only
    # root can read, all of those connections fail. Comment out just those lines
    # (they are client-certificate settings, unused for loopback connections)
    # rather than widening access to a private key.
    local cnfnum cnfpath cnflines unreadable
    for cnf in /etc/my.cnf /etc/my.cnf.d/*.cnf /etc/mysql/my.cnf /etc/mysql/conf.d/*.cnf \
               /etc/mysql/mariadb.conf.d/*.cnf; do
        [[ -f "$cnf" ]] || continue
        cnflines=()
        unreadable=0
        while IFS=$'\t' read -r cnfnum cnfpath; do
            [[ -n "$cnfnum" ]] || continue
            cnflines+=("$cnfnum")
            if [[ -e "$cnfpath" ]] && ! runuser -u nobody -- test -r "$cnfpath" 2>/dev/null; then
                unreadable=1
            fi
        done < <(awk '/^[[:space:]]*\[/ { sect = tolower($0); gsub(/[[:space:]]/, "", sect) }
            sect ~ /^\[(client|client-server|client-mariadb|mysql)\]/ && /^[[:space:]]*ssl[-_](key|cert|ca)[[:space:]]*=/ {
                v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); gsub(/"/, "", v)
                printf "%d\t%s\n", NR, v }' "$cnf")
        # All or nothing: a client certificate without its key aborts every
        # connection during the TLS handshake, root's included.
        ((unreadable)) || continue
        [[ -e "${cnf}.pre-ispconfig" ]] || cp -a "$cnf" "${cnf}.pre-ispconfig"
        for cnfnum in "${cnflines[@]}"; do
            sed -i "${cnfnum}s|^|# disabled by the ISPConfig installer (unreadable by non-root clients): |" "$cnf"
        done
        __warn "Disabled client ssl-key/ssl-cert/ssl-ca lines in ${cnf} (backup: ${cnf}.pre-ispconfig)"
    done

    local sslfile
    while read -r sslfile; do
        [[ -f "$sslfile" ]] || continue
        runuser -u mysql -- test -r "$sslfile" 2>/dev/null && continue
        if command -v setfacl >/dev/null 2>&1 && setfacl -m u:mysql:r "$sslfile"; then
            __warn "MariaDB config uses ${sslfile}; granted the mysql user read access (ACL)"
        else
            __warn "MariaDB config uses ${sslfile}, which the mysql user cannot read — MariaDB will not start"
        fi
    done < <(grep -hE -- '^[[:space:]]*ssl[-_](key|cert|ca)[[:space:]]*=' \
        /etc/my.cnf /etc/my.cnf.d/*.cnf /etc/mysql/my.cnf /etc/mysql/conf.d/*.cnf \
        /etc/mysql/mariadb.conf.d/*.cnf 2>/dev/null \
        | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+$//; s/^"(.*)"$/\1/')
}

__install_mysql() {
    __log "Installing MariaDB server..."
    case "$PACKAGE_MANAGER" in
        "apt")       apt-get install -y mariadb-server mariadb-client ;;
        "dnf"|"yum") $PACKAGE_MANAGER install -y mariadb-server mariadb ;;
        "zypper")    zypper install -y mariadb mariadb-client ;;
    esac

    __prepare_mariadb
    systemctl enable mariadb
    systemctl start mariadb

    # Prefer 'mariadb' binary (MariaDB 10.4+), fall back to 'mysql'
    local MYSQL_BIN="mysql"
    command -v mariadb >/dev/null 2>&1 && MYSQL_BIN="mariadb"

    __log "Securing MariaDB (${MYSQL_BIN})..."

    # Determine how to connect for initial setup.
    # Debian 10.4+ maps unix_socket auth to the 'mysql' OS user, not 'root'.
    # RHEL/older systems allow OS root to connect directly via socket.
    local INIT_CMD=""
    if runuser -u mysql -- ${MYSQL_BIN} -e "SELECT 1" >/dev/null 2>&1; then
        INIT_CMD="runuser -u mysql -- ${MYSQL_BIN}"
    elif ${MYSQL_BIN} -e "SELECT 1" >/dev/null 2>&1; then
        INIT_CMD="${MYSQL_BIN}"
    else
        __error "Cannot connect to MariaDB for initial setup — check installation"
    fi

    # Set root password, trying modern then legacy syntax
    ${INIT_CMD} -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ISPCONFIG_MYSQL_ROOT_PASSWORD}'" 2>/dev/null || \
    ${INIT_CMD} -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${ISPCONFIG_MYSQL_ROOT_PASSWORD}')" 2>/dev/null || \
    ${INIT_CMD} -e "UPDATE mysql.user SET Password=PASSWORD('${ISPCONFIG_MYSQL_ROOT_PASSWORD}') WHERE User='root'; FLUSH PRIVILEGES;"

    # All subsequent operations use password auth
    local MYSQL="${MYSQL_BIN} -u root -p${ISPCONFIG_MYSQL_ROOT_PASSWORD}"

    # ISPConfig's autoinstaller connects over TCP (127.0.0.1) rather than the
    # Unix socket, since PHP's compiled-in default socket path can mismatch
    # MariaDB's actual socket across the multiple PHP builds this script
    # installs. Default MariaDB installs only create root@localhost, so add
    # a root@127.0.0.1 user with the same password for the TCP connection.
    ${MYSQL} -e "CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${ISPCONFIG_MYSQL_ROOT_PASSWORD}'"
    # On a retry the account already exists with the previous run's password;
    # CREATE USER IF NOT EXISTS leaves it untouched, so set it explicitly.
    ${MYSQL} -e "ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '${ISPCONFIG_MYSQL_ROOT_PASSWORD}'" 2>/dev/null || \
    ${MYSQL} -e "SET PASSWORD FOR 'root'@'127.0.0.1' = PASSWORD('${ISPCONFIG_MYSQL_ROOT_PASSWORD}')" 2>/dev/null || \
    ${MYSQL} -e "UPDATE mysql.user SET Password=PASSWORD('${ISPCONFIG_MYSQL_ROOT_PASSWORD}') WHERE User='root' AND Host='127.0.0.1'; FLUSH PRIVILEGES;"
    ${MYSQL} -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION"

    ${MYSQL} -e "DELETE FROM mysql.user WHERE User=''"
    ${MYSQL} -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1')"
    ${MYSQL} -e "DROP DATABASE IF EXISTS test"
    ${MYSQL} -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'"
    ${MYSQL} -e "FLUSH PRIVILEGES"

    cat > /root/.my.cnf << EOF
[client]
user=root
password=${ISPCONFIG_MYSQL_ROOT_PASSWORD}
EOF
    chmod 600 /root/.my.cnf
    __success "MariaDB secured"
}

# ── PHP ───────────────────────────────────────────────────────────────────────
__install_php() {
    __log "Installing multiple PHP versions..."
    case "$DISTRO" in
        "ubuntu"|"debian")            __install_php_debian ;;
        "centos"|"rhel"|"almalinux"|"rocky"|"fedora") __install_php_rhel ;;
        "opensuse"|"opensuse-leap"|"sles") __install_php_suse ;;
    esac
    __configure_php_versions
}

__install_php_debian() {
    __log "Adding Ondrej PHP repository..."
    if [[ "$DISTRO" == "ubuntu" ]]; then
        # Only add the Ondrej PPA if it has a release for this Ubuntu codename.
        # Brand-new Ubuntu releases (e.g. 26.04/resolute) may not yet be in the PPA;
        # using a mismatched-codename fallback causes ABI breakage because the compiled
        # PHP binaries depend on system library sonames that have changed.  When the PPA
        # has no release for this codename we skip it and rely on the distro's native PHP
        # packages (e.g. PHP 8.5 ships natively on Ubuntu 26.04).
        local _codename
        _codename=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")
        if [[ -z "$_codename" ]] || curl -q -sfI \
                "https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/${_codename}/Release" \
                >/dev/null 2>&1; then
            add-apt-repository -y ppa:ondrej/php
        else
            __warn "Ondrej PPA has no release for '${_codename}' — using distro PHP packages only"
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
            __warn "PHP ${version} not available in repos — skipping"
            continue
        fi
        __log "Installing PHP ${version}..."

        # Install core runtime packages — these must exist if the version is available.
        # Note: php${version}-pcntl is NOT a separate package on Ondrej PPA;
        # PCNTL is compiled into the PHP CLI binary directly.
        if ! apt-get install -y \
            php${version} php${version}-cli php${version}-fpm php${version}-cgi \
            php${version}-common; then
            __warn "PHP ${version} core install failed — skipping this version"
            apt-get install -f -y 2>/dev/null || true
            continue
        fi

        # Install extension packages one at a time, skipping any that are missing.
        # Some extensions (opcache, imap, gettext, exif, sockets) are built directly
        # into the PHP binary from certain versions onward and have no separate package.
        for ext in mysql pgsql sqlite3 gd imagick mbstring xml curl zip soap intl \
                   bcmath opcache readline bz2 xsl tidy ldap imap gettext exif sockets \
                   redis memcached; do
            local pkg="php${version}-${ext}"
            if apt-cache show "$pkg" >/dev/null 2>&1; then
                apt-get install -y "$pkg" 2>/dev/null || true
            fi
        done

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
            __save_var PHP_DEFAULT
            break
        fi
    done
    __log "Setting PHP ${PHP_DEFAULT} as system default"
    update-alternatives --set php     "/usr/bin/php${PHP_DEFAULT}"     2>/dev/null || true
    update-alternatives --set php-cgi "/usr/bin/php-cgi${PHP_DEFAULT}" 2>/dev/null || true

    for version in "${PHP_VERSIONS[@]}"; do
        systemctl enable php${version}-fpm 2>/dev/null || true
        systemctl start  php${version}-fpm 2>/dev/null || true
    done
}

__install_php_rhel() {
    __log "Adding Remi PHP repository..."
    local major_version
    major_version="${DISTRO_VERSION%%.*}"
    $PACKAGE_MANAGER install -y "https://rpms.remirepo.net/enterprise/remi-release-${major_version}.rpm" 2>/dev/null || \
        __warn "Remi repo install failed for version ${major_version}"

    for version in "${PHP_VERSIONS[@]}"; do
        local vc=${version//./}
        # Skip versions not available in Remi
        if ! $PACKAGE_MANAGER info --enablerepo=remi "php${vc}" >/dev/null 2>&1; then
            __warn "PHP ${version} not available in Remi — skipping"
            continue
        fi
        __log "Installing PHP ${version}..."
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
            __warn "PHP ${version} install had errors — some modules may be missing"
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
            __save_var PHP_DEFAULT
            break
        fi
    done
    local dvc="${PHP_DEFAULT//./}"
    __log "Setting PHP ${PHP_DEFAULT} as system default"
    alternatives --install /usr/bin/php php /opt/remi/php${dvc}/root/usr/bin/php 100 2>/dev/null || true
}

__install_php_suse() {
    local available=("8.2" "8.1" "8.0" "7.4")
    for version in "${available[@]}"; do
        local vc=${version//./}
        __log "Installing PHP ${version}..."
        zypper install -y \
            php${vc} php${vc}-cli php${vc}-fpm php${vc}-mysql \
            php${vc}-gd php${vc}-mbstring php${vc}-xml php${vc}-curl \
            php${vc}-zip php${vc}-soap php${vc}-intl php${vc}-bcmath \
            php${vc}-opcache 2>/dev/null || __warn "Some PHP ${version} packages unavailable"
        systemctl enable php-fpm 2>/dev/null || true
        systemctl start  php-fpm 2>/dev/null || true
    done
}

__configure_php_versions() {
    __log "Tuning PHP ini files..."
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
    __log "Installing mail services (Postfix + Dovecot)..."
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
                || __warn "opendkim not available — DKIM will be skipped"
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
                || __warn "opendkim not available — DKIM will be skipped"
            ;;
        "zypper")
            zypper install -y \
                postfix postfix-mysql \
                dovecot dovecot-backend-mysql
            zypper install -y opendkim 2>/dev/null \
                || __warn "opendkim not available — DKIM will be skipped"
            ;;
    esac
    systemctl enable postfix dovecot
    systemctl start  postfix 2>/dev/null || true
    # Dovecot start failures are non-fatal here — Dovecot 2.4 (Ubuntu 26.04)
    # requires config changes not yet applied; ISPConfig will write the final
    # config and restart dovecot during its autoinstall phase.
    systemctl start  dovecot 2>/dev/null || true
}

__configure_mail_public() {
    __log "Configuring mail for public use (inbound + outbound + secure retrieval)..."

    # ── Postfix: TLS and delivery hardening ──────────────────────────────────
    # Use ISPConfig's SSL cert for mail TLS (already created by ISPConfig install)
    local mail_cert="/usr/local/ispconfig/interface/ssl/ispserver.crt"
    local mail_key="/usr/local/ispconfig/interface/ssl/ispserver.key"
    # Dovecot's packaged service runs in a confined SELinux domain; use the
    # distro-managed certificate paths unless ISPConfig's mail certificate exists.
    if [[ ! -r "$mail_cert" || ! -r "$mail_key" ]]; then
        mail_cert="/etc/pki/dovecot/certs/dovecot.pem"
        mail_key="/etc/pki/dovecot/private/dovecot.pem"
    fi

    # Outbound: opportunistic TLS — required by Gmail, Yahoo, Outlook, etc.
    # A base config can relay through an smtps (465) relayhost with
    # smtp_tls_wrappermode=yes; Postfix refuses wrapper mode below "encrypt",
    # which would defer every outbound message.
    local smtp_tls_level="may"
    [[ "$(postconf -h smtp_tls_wrappermode 2>/dev/null)" == "yes" ]] && smtp_tls_level="encrypt"
    postconf -e "smtp_tls_security_level = ${smtp_tls_level}"
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
    if ! grep -q -- "^submission " /etc/postfix/master.cf; then
        cat >> /etc/postfix/master.cf << 'MASTEREOF'
submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
MASTEREOF
        __log "Enabled SMTP submission on port 587"
    fi

    if ! grep -q -- "^smtps " /etc/postfix/master.cf; then
        cat >> /etc/postfix/master.cf << 'MASTEREOF'
smtps inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
MASTEREOF
        __log "Enabled SMTPS on port 465"
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
            # AlmaLinux's main dovecot.conf may define these settings again;
            # update that active override or it wins over conf.d/10-ssl.conf.
            if [[ -f /etc/dovecot/dovecot.conf ]]; then
                sed -i \
                    -e "s|^ssl_cert = .*|ssl_cert = <${mail_cert}|" \
                    -e "s|^ssl_key = .*|ssl_key = <${mail_key}|" \
                    /etc/dovecot/dovecot.conf
            fi
        fi
        if grep -q -- "ssl_min_protocol\|ssl_protocols" "$dovecot_ssl_conf"; then
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
    if ! postconf smtpd_milters 2>/dev/null | grep -q -- "8891"; then
        postconf -e "smtpd_milters = inet:localhost:8891"
        postconf -e "non_smtpd_milters = inet:localhost:8891"
    fi

    # Debian's init wrapper reads /etc/default/opendkim and its SOCKET value
    # overrides the Socket line in opendkim.conf, leaving the daemon on a unix
    # socket while Postfix's milter points at inet:localhost:8891.
    if [[ -f /etc/default/opendkim ]]; then
        sed -i -e '/^[[:space:]]*#\?[[:space:]]*SOCKET=/d' /etc/default/opendkim
        echo 'SOCKET=inet:8891@localhost' >> /etc/default/opendkim
    fi

    systemctl enable opendkim 2>/dev/null || true
    # restart, not start: Debian starts the daemon at package install time
    systemctl restart opendkim 2>/dev/null || true

    systemctl restart postfix dovecot 2>/dev/null || true
    __success "Mail configured: SMTP/S + submission + IMAP/S + POP3/S + DKIM framework"
}

# ── FTP ───────────────────────────────────────────────────────────────────────
__install_ftp() {
    __log "Installing ProFTPd..."
    case "$PACKAGE_MANAGER" in
        "apt")
            # proftpd-mod-mysql is a separate package on some Debian versions but
            # may be merged into proftpd or absent on others — treat it as optional
            apt-get install -y proftpd-basic \
                || apt-get install -y proftpd \
                || __warn "proftpd install failed — FTP may not be available"
            apt-get install -y proftpd-mod-mysql 2>/dev/null \
                || __warn "proftpd-mod-mysql unavailable — MySQL-based FTP auth disabled"
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
                || __warn "proftpd install failed — FTP may not be available"
            ;;
        "zypper")
            zypper install -y proftpd \
                || __warn "proftpd install failed — FTP may not be available"
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
            apt)    apt-get install -y "$pkg" 2>/dev/null || __warn "Package unavailable, skipping: $pkg" ;;
            dnf|yum) $pm install -y "$pkg" 2>/dev/null  || __warn "Package unavailable, skipping: $pkg" ;;
            zypper) zypper install -y "$pkg" 2>/dev/null || __warn "Package unavailable, skipping: $pkg" ;;
        esac
    done
}

__install_tools() {
    __log "Installing additional tools..."
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

    # Package scripts may start BIND without enabling it for the next boot.
    systemctl enable --now named
}

# ── fail2ban install + jails ──────────────────────────────────────────────────
__install_fail2ban() {
    __log "Installing fail2ban..."
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
    # ignoreip includes loopback so local panel proxy traffic is never banned.
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

    # Pre-create log files that fail2ban watches so it can start without errors
    # even before the services have written anything.
    mkdir -p /var/log/ispconfig
    touch /var/log/ispconfig/auth.log
    mkdir -p /var/log/proftpd
    touch /var/log/proftpd/proftpd.log

    systemctl enable fail2ban
    systemctl restart fail2ban
    __log "fail2ban installed and configured"
}

# ── ISPConfig install ─────────────────────────────────────────────────────────
__install_ispconfig() {
    __log "Downloading ISPConfig..."
    cd /tmp
    wget -O ispconfig.tar.gz https://www.ispconfig.org/downloads/ISPConfig-3-stable.tar.gz
    tar xfz ispconfig.tar.gz
    cd ispconfig3*/install/

    __log "Running ISPConfig autoinstall..."

    # ISPConfig uses INI-format autoinstall files (see docs/autoinstall_samples/)
    # ispconfig_port is the loopback-only ISPConfig panel backend port
    cat > /tmp/ispconfig_autoinstall.ini << EOF
[install]
language=en
install_mode=expert
hostname=${HOSTNAME}
# 127.0.0.1 forces a TCP connection instead of a Unix socket — "localhost"
# makes PHP's mysqli/PDO use its compiled-in default socket path, which can
# mismatch MariaDB's actual socket location across the multiple PHP builds
# this script installs, causing "Unable to connect ... No such file or directory".
mysql_hostname=127.0.0.1
mysql_port=3306
mysql_root_user=root
mysql_root_password=${ISPCONFIG_MYSQL_ROOT_PASSWORD}
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
install_ispconfig_web_interface=y
EOF

    # Locate PHP binary — prefer the system default, fall back to any installed version
    local php_bin
    php_bin=$(command -v php 2>/dev/null)
    if [[ -z "$php_bin" ]]; then
        local php_candidates=()
        local f
        for f in /usr/bin/php[0-9]* /usr/local/bin/php[0-9]*; do
            [[ -e "$f" && "$f" != *cgi* ]] && php_candidates+=("$f")
        done
        ((${#php_candidates[@]} > 0)) && php_bin=$(printf '%s\n' "${php_candidates[@]}" | sort -V | tail -1)
    fi
    if [[ -z "$php_bin" ]]; then
        __error "No PHP binary found — PHP installation must have failed. Check logs above."
    fi
    __log "Using PHP: $(${php_bin} -r 'echo PHP_VERSION;' 2>/dev/null)"

    ${php_bin} install.php --autoinstall=/tmp/ispconfig_autoinstall.ini
    rm -f /tmp/ispconfig_autoinstall.ini

    # ISPConfig's autoinstall.ini has no key to set the panel admin username —
    # install.php always seeds it as "admin". Rename it in place when the
    # caller asked for something else; sys_user.username is only ever matched
    # by string on login, so this is safe post-install.
    if [[ "$ISPCONFIG_ADMIN_USER" != "admin" ]]; then
        local mysql_bin="mysql"
        command -v mariadb >/dev/null 2>&1 && mysql_bin="mariadb"
        "$mysql_bin" -u root -p"${ISPCONFIG_MYSQL_ROOT_PASSWORD}" dbispconfig -e \
            "UPDATE sys_user SET username='${ISPCONFIG_ADMIN_USER}' WHERE username='admin';"
        __log "Renamed ISPConfig admin user to '${ISPCONFIG_ADMIN_USER}'"
    fi

    # The panel, ISPConfig's server scripts, Postfix's MySQL maps and amavisd
    # all connect to 127.0.0.1, which MariaDB sees as 'localhost'. The
    # autoinstaller only grants the server FQDN, so every connection was denied
    # (panel 500, local mail deferred, amavisd dying on each message). Pointing
    # db_host at the FQDN instead is fragile: it can resolve to an IPv6
    # link-local address that MariaDB does not listen on. Grant the loopback
    # host names the same privileges instead.
    local grant_bin="mysql"
    command -v mariadb >/dev/null 2>&1 && grant_bin="mariadb"
    local grant_host
    for grant_host in localhost 127.0.0.1; do
        local grant_sql="CREATE USER IF NOT EXISTS 'ispconfig'@'${grant_host}' IDENTIFIED BY '${ISPCONFIG_DB_PASSWORD}';"
        grant_sql+=" GRANT SELECT, INSERT, UPDATE, DELETE ON dbispconfig.* TO 'ispconfig'@'${grant_host}'; FLUSH PRIVILEGES;"
        "$grant_bin" -u root -p"${ISPCONFIG_MYSQL_ROOT_PASSWORD}" -e "$grant_sql"
    done
    __log "Granted the ispconfig DB user access from localhost and 127.0.0.1"
}

# ── Apache direct-listener configuration ─────────────────────────────────────
__configure_apache_backend() {
    __log "Configuring Apache for direct HTTP and HTTPS traffic..."

    local listen_file="${APACHE_CONF_DIR}/conf/httpd.conf"
    local config_dirs=("${APACHE_CONF_DIR}" "${APACHE_VHOST_DIR}")
    case "$PACKAGE_MANAGER" in
        apt)
            listen_file="${APACHE_CONF_DIR}/ports.conf"
            a2dismod mpm_prefork mpm_worker remoteip 2>/dev/null || true
            a2enmod mpm_event ssl rewrite headers proxy proxy_http
            a2enmod suexec 2>/dev/null || true
            config_dirs=("${APACHE_CONF_DIR}/sites-available" "${APACHE_CONF_DIR}/sites-enabled" "${APACHE_CONF_DIR}/conf-available")
            ;;
        zypper)
            listen_file="${APACHE_CONF_DIR}/httpd.conf"
            a2dismod mpm_prefork mpm_worker remoteip 2>/dev/null || true
            a2enmod mpm_event ssl rewrite headers proxy proxy_http
            a2enmod suexec 2>/dev/null || true
            config_dirs=("${APACHE_CONF_DIR}" "${APACHE_VHOST_DIR}" "${APACHE_CONF_EXTRA}")
            ;;
        *)
            local module module_file module_loads="" module_tmp
            for module in ssl proxy proxy_http headers rewrite proxy_fcgi; do
                module_file="${APACHE_CONF_DIR}/modules/mod_${module}.so"
                if [[ -f "$module_file" ]] \
                    && ! grep -Rqs -- "^[[:space:]]*LoadModule[[:space:]]\+${module}_module" "${APACHE_CONF_DIR}/conf.modules.d" "$listen_file" 2>/dev/null; then
                    module_loads+="LoadModule ${module}_module modules/mod_${module}.so\n"
                fi
            done
            if [[ -n "$module_loads" ]]; then
                module_tmp=$(mktemp)
                printf '%b' "$module_loads" > "$module_tmp"
                cat "$listen_file" >> "$module_tmp"
                cat "$module_tmp" > "$listen_file"
                rm -f "$module_tmp"
            fi
            [[ -f /etc/httpd/conf.modules.d/00-mpm.conf ]] && cat > /etc/httpd/conf.modules.d/00-mpm.conf <<'MPMEOF'
# LoadModule mpm_prefork_module modules/mod_mpm_prefork.so
# LoadModule mpm_worker_module modules/mod_mpm_worker.so
LoadModule mpm_event_module modules/mod_mpm_event.so
MPMEOF
            if [[ -f /etc/httpd/modules/mod_suexec.so ]] \
                && ! grep -q -- '^[[:space:]]*LoadModule[[:space:]]\+suexec_module' "$listen_file"; then
                sed -i '/^LoadModule fcgid_module /a LoadModule suexec_module modules/mod_suexec.so' "$listen_file"
            fi
            config_dirs=("${APACHE_CONF_DIR}/conf.d" "${APACHE_CONF_DIR}/conf/sites-available" "${APACHE_CONF_DIR}/conf/sites-enabled" "${APACHE_CONF_DIR}/conf/vhosts.d" "${APACHE_VHOST_DIR}")
            ;;
    esac

    [[ -e "${listen_file}.pre-ispconfig" ]] || cp -a "$listen_file" "${listen_file}.pre-ispconfig"
    if grep -Eq -- '(:81|:8443)' "$listen_file"; then
        [[ -e "${listen_file}.pre-ispconfig" ]] || cp -a "$listen_file" "${listen_file}.pre-ispconfig"
        sed -i \
            -e 's|:81>|:80>|g' \
            -e 's|:8443>|:443>|g' \
            -e '/^[[:space:]]*NameVirtualHost/d' "$listen_file"
    fi

    local ispc_admin_vhost="${APACHE_CONF_DIR}/conf/sites-available/ispconfig.vhost"
    local ispc_apps_vhost="${APACHE_CONF_DIR}/conf/sites-available/apps.vhost"
    [[ -f "${APACHE_VHOST_DIR}/ispconfig.vhost" ]] && ispc_admin_vhost="${APACHE_VHOST_DIR}/ispconfig.vhost"
    [[ -f "${APACHE_VHOST_DIR}/apps.vhost" ]] && ispc_apps_vhost="${APACHE_VHOST_DIR}/apps.vhost"
    local detected_admin_port detected_apps_port
    detected_admin_port=$(awk '/^[[:space:]]*Listen[[:space:]]+[0-9]+/ {print $2; exit}' "$ispc_admin_vhost" 2>/dev/null || true)
    detected_apps_port=$(awk '/^[[:space:]]*Listen[[:space:]]+[0-9]+/ {print $2; exit}' "$ispc_apps_vhost" 2>/dev/null || true)
    APACHE_ADMIN_PORT="${detected_admin_port:-7080}"
    APACHE_APPS_PORT="${detected_apps_port:-7081}"

    local vhost_dir file
    for vhost_dir in "${config_dirs[@]}"; do
        [[ -d "$vhost_dir" ]] || continue
        while IFS= read -r -d '' file; do
            if grep -Eq -- '(:81|:8443|^[[:space:]]*Listen[[:space:]])' "$file"; then
                [[ -e "${file}.pre-ispconfig" ]] || cp -a "$file" "${file}.pre-ispconfig"
                sed -i \
                    -e 's|:81>|:80>|g' \
                    -e 's|:8443>|:443>|g' \
                    -e '/^[[:space:]]*Listen[[:space:]]/d' \
                    -e '/^[[:space:]]*NameVirtualHost/d' "$file"
            fi
        done < <(find "$vhost_dir" -maxdepth 1 -type f \( -name '*.conf' -o -name '*.vhost' \) -print0 2>/dev/null)
    done

    [[ -e "${listen_file}.pre-ispconfig" ]] || cp -a "$listen_file" "${listen_file}.pre-ispconfig"
    sed -i '/^[[:space:]]*Listen[[:space:]]/d' "$listen_file"
    cat >> "$listen_file" <<LISTENEOF

# ISPConfig direct web and panel listeners
Listen 80
Listen 443
Listen 127.0.0.1:${APACHE_ADMIN_PORT}
Listen 127.0.0.1:${APACHE_APPS_PORT}
LISTENEOF

    rm -f "${APACHE_CONF_EXTRA}/remoteip.conf" "${APACHE_CONF_DIR}/conf-available/remoteip.conf" \
        "${APACHE_CONF_EXTRA}/forwarded-https.conf" "${APACHE_CONF_DIR}/conf-available/forwarded-https.conf"

    case "$PACKAGE_MANAGER" in
        apt) a2disconf remoteip forwarded-https 2>/dev/null || true ;;
    esac

    if [[ "$DISTRO" == opensuse || "$DISTRO" == opensuse-leap || "$DISTRO" == sles ]]; then
        cat >> "${APACHE_CONF_DIR}/httpd.conf" <<'MPMTUNEEOF'

<IfModule mpm_event_module>
    StartServers 4
    MinSpareThreads 25
    MaxSpareThreads 75
    ThreadLimit 64
    ThreadsPerChild 25
    MaxRequestWorkers 400
    MaxConnectionsPerChild 10000
</IfModule>
MPMTUNEEOF
    fi

    __save_var APACHE_ADMIN_PORT
    __save_var APACHE_APPS_PORT

    local php_cgi_bin="" php_ver="" php_rc="" starter starter_tmp starter_attrs restore_immutable
    if [[ "$PACKAGE_MANAGER" == apt ]]; then
        php_cgi_bin=$(update-alternatives --query php-cgi 2>/dev/null | awk '/^Value:/ {print $2}')
        [[ -n "$php_cgi_bin" ]] || php_cgi_bin=$(command -v "php-cgi${PHP_DEFAULT}" || command -v php-cgi 2>/dev/null || true)
        php_ver=$(printf '%s' "${php_cgi_bin##*/}" | grep -oE -- '[0-9]+\.[0-9]+' | head -1)
        [[ -n "$php_ver" ]] || php_ver="$PHP_DEFAULT"
        php_rc="/etc/php/${php_ver}/cgi/"
    else
        local php_digits
        for php_ver in "${PHP_VERSIONS[@]}"; do
            php_digits="${php_ver//./}"
            php_cgi_bin="/opt/remi/php${php_digits}/root/usr/bin/php-cgi"
            [[ -x "$php_cgi_bin" ]] && break
            php_cgi_bin=""
        done
        [[ -n "$php_cgi_bin" ]] && php_rc="/etc/opt/remi/php${php_digits}/"
    fi
    if [[ -n "$php_cgi_bin" ]]; then
        for starter in /var/www/php-fcgi-scripts/ispconfig/.php-fcgi-starter \
                       /var/www/php-fcgi-scripts/apps/.php-fcgi-starter; do
            [[ -f "$starter" ]] || continue
            starter_tmp=$(mktemp)
            starter_attrs=$(lsattr -d "$starter" 2>/dev/null | awk '{print $1}')
            restore_immutable=false
            [[ "$starter_attrs" == *i* ]] && restore_immutable=true
            chattr -i "$starter" 2>/dev/null || true
            sed \
                -e "s|^PHPRC=.*|PHPRC=${php_rc}|" \
                -e "s|^exec /usr/bin/php-cgi|exec ${php_cgi_bin}|" \
                "$starter" > "$starter_tmp"
            cp "$starter_tmp" "$starter"
            [[ "$restore_immutable" == true ]] && chattr +i "$starter" 2>/dev/null || true
            rm -f "$starter_tmp"
        done
    fi

    apachectl configtest
    __log "Apache listens directly on :80 and :443; ISPConfig panel remains on :${APACHE_ADMIN_PORT} internally"
}

# ── SELinux labels (RHEL-family) ─────────────────────────────────────────────
# Everything ISPConfig creates is born unconfined_u:usr_t / httpd_sys_content_t,
# which httpd_t and httpd_suexec_t may not read or write. Preserve the labels
# required by ISPConfig's CGI, vlogger, and writable runtime paths.
__configure_selinux() {
    if ! command -v semanage >/dev/null 2>&1; then
        __warn "semanage not available — skipping SELinux labelling"
        return 0
    fi
    if [[ "$(getenforce 2>/dev/null)" == "Disabled" ]]; then
        __log "SELinux disabled — skipping labelling"
        return 0
    fi

    __log "Applying SELinux policy for ISPConfig..."

    # Apache proxies the panel request to its local ISPConfig listener.
    setsebool -P httpd_can_network_connect on
    setsebool -P httpd_enable_homedirs on 2>/dev/null || true

    # ISPConfig's internal panel and apps listeners need the Apache port type.
    local p
    for p in "$APACHE_ADMIN_PORT" "$APACHE_APPS_PORT"; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        semanage port -d -t transproxy_port_t -p tcp "$p" 2>/dev/null || true
        semanage port -d -t unreserved_port_t -p tcp "$p" 2>/dev/null || true
        semanage port -a -t http_port_t -p tcp "$p" 2>/dev/null \
            || semanage port -m -t http_port_t -p tcp "$p" 2>/dev/null || true
    done

    # 3. ISPConfig's own tree is written at runtime by httpd_t/suexec (sessions,
    #    IDS storage, cache) — label it read-write instead of the default usr_t.
    semanage fcontext -a -t httpd_sys_rw_content_t "/usr/local/ispconfig(/.*)?" 2>/dev/null \
        || semanage fcontext -m -t httpd_sys_rw_content_t "/usr/local/ispconfig(/.*)?" 2>/dev/null \
        || true
    semanage fcontext -a -t var_log_t "/var/log/ispconfig(/.*)?" 2>/dev/null \
        || semanage fcontext -m -t var_log_t "/var/log/ispconfig(/.*)?" 2>/dev/null \
        || true
    semanage fcontext -a -t httpd_log_t "/var/log/ispconfig/auth.log" 2>/dev/null \
        || semanage fcontext -m -t httpd_log_t "/var/log/ispconfig/auth.log" 2>/dev/null \
        || true
    semanage fcontext -a -t httpd_sys_script_exec_t "/usr/local/ispconfig/server/scripts/vlogger" 2>/dev/null \
        || semanage fcontext -m -t httpd_sys_script_exec_t "/usr/local/ispconfig/server/scripts/vlogger" 2>/dev/null \
        || true

    # 4. The PHP-FCGI starters are executed by suexec, which requires
    #    httpd_sys_script_exec_t. ISPConfig ships them immutable AND mislabelled;
    #    an immutable file cannot be relabelled, so clear the flag first.
    for starter in /var/www/php-fcgi-scripts/*/.php-fcgi-starter; do
        [[ -f "$starter" ]] || continue
        chattr -i "$starter" 2>/dev/null || true
    done
    semanage fcontext -a -t httpd_sys_script_exec_t "/var/www/php-fcgi-scripts(/.*)?" 2>/dev/null \
        || semanage fcontext -m -t httpd_sys_script_exec_t "/var/www/php-fcgi-scripts(/.*)?" 2>/dev/null \
        || true

    # 5. vlogger writes per-vhost log dirs under /var/log/ispconfig; without a
    #    var_log_t label httpd_t is denied and every vhost logs AH00106.
    #    vlogger runs as root but inside httpd_sys_script_t, which lacks
    #    CAP_DAC_OVERRIDE — it cannot create anything under a directory it does
    #    not own. Own the tree by root and give the Apache group read access;
    #    setgid keeps new files group-readable for Apache.
    mkdir -p /var/log/ispconfig/httpd
    chown -R root:apache /var/log/ispconfig/httpd
    chmod 2775 /var/log/ispconfig/httpd
    chmod 0755 /usr/local/ispconfig/server /usr/local/ispconfig/server/scripts \
        /usr/local/ispconfig/server/scripts/vlogger 2>/dev/null || true

    # 6. postfix's postalias reads /var/lib/aliases, created outside the package
    #    and so left as var_lib_t.
    semanage fcontext -a -t postfix_etc_t "/var/lib/aliases(/.*)?" 2>/dev/null \
        || semanage fcontext -m -t postfix_etc_t "/var/lib/aliases(/.*)?" 2>/dev/null || true

    # 6b. postfix reads the mailman maps ISPConfig creates here, and must traverse the directory.
    semanage fcontext -a -t postfix_etc_t "/var/lib/mailman(/data(/.*)?)?" 2>/dev/null \
        || semanage fcontext -m -t postfix_etc_t "/var/lib/mailman(/data(/.*)?)?" 2>/dev/null || true

    # 7. PHP's OPcache locks a memfd shared-memory segment. Under
    #    httpd_sys_script_t that memfd is typed tmpfs_t and the lock is denied,
    #    which kills the FastCGI child before it can emit headers (HTTP 500 on
    #    every request). OPcache buys little for short-lived CGI processes, so
    #    disable it for the CGI SAPI only — CLI and FPM are unaffected.
    local _phpc _ini _phpver
    for _phpc in /opt/remi/php*/root/usr/bin/php-cgi /usr/bin/php-cgi; do
        [[ -x "$_phpc" ]] || continue
        if [[ "$_phpc" == /opt/remi/php*/root/usr/bin/php-cgi ]]; then
            local _phpver="${_phpc#/opt/remi/}"
            _phpver="${_phpver%%/*}"
            _ini="/etc/opt/remi/${_phpver}/php.d"
        else
            _ini="/etc/php.d"
        fi
        [[ -d "$_ini" ]] || continue
        printf '%s\n' \
            '; Disabled for CGI: OPcache memfd locking is denied under' \
            '; httpd_sys_script_t and aborts the FastCGI child (HTTP 500).' \
            '[opcache]' \
            'opcache.enable=0' \
            'opcache.enable_cli=0' > "${_ini}/99-opcache-cgi-off.ini"
        __log "Disabled OPcache for CGI (${_ini})"
    done

    restorecon -R /usr/local/ispconfig /var/log/ispconfig /var/www/php-fcgi-scripts /var/lib/mailman "$LETSENCRYPT_WEBROOT" 2>/dev/null || true

    __success "SELinux policy applied (ports, booleans, file contexts)"
}

# ── ISPConfig panel hostname on Apache ────────────────────────────────────────
__configure_ispconfig_apache() {
    local panel_conf="${APACHE_VHOST_DIR}/10-ispconfig-panel.conf"
    local ssl_conf="${APACHE_CONF_EXTRA}/ispconfig-ssl.conf"
    mkdir -p "${APACHE_CONF_EXTRA}" "${APACHE_VHOST_DIR}"
    cat > "$ssl_conf" <<'SSLEOF'
SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
SSLEOF

    case "$PACKAGE_MANAGER" in
        apt)
            a2enmod proxy proxy_http headers ssl rewrite
            a2enconf ispconfig-ssl
            cat > "$panel_conf" <<PANELEOF
<VirtualHost *:80>
    ServerName ${PANEL_HOSTNAME}
    Redirect permanent / https://${PANEL_HOSTNAME}/
</VirtualHost>

<VirtualHost *:443>
    ServerName ${PANEL_HOSTNAME}
    SSLEngine on
    SSLCertificateFile ${PANEL_CERT_FILE}
    SSLCertificateKeyFile ${PANEL_KEY_FILE}
    Header always set Strict-Transport-Security "max-age=31536000"
    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "https"
    ProxyPass / http://${APACHE_BACKEND_IP}:${APACHE_ADMIN_PORT}/ connectiontimeout=5 timeout=300
    ProxyPassReverse / http://${APACHE_BACKEND_IP}:${APACHE_ADMIN_PORT}/
</VirtualHost>
PANELEOF
            a2ensite 10-ispconfig-panel
            ;;
        *)
            cat > "$panel_conf" <<PANELEOF
<VirtualHost *:80>
    ServerName ${PANEL_HOSTNAME}
    Redirect permanent / https://${PANEL_HOSTNAME}/
</VirtualHost>

<VirtualHost *:443>
    ServerName ${PANEL_HOSTNAME}
    SSLEngine on
    SSLCertificateFile ${PANEL_CERT_FILE}
    SSLCertificateKeyFile ${PANEL_KEY_FILE}
    Header always set Strict-Transport-Security "max-age=31536000"
    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "https"
    ProxyPass / http://${APACHE_BACKEND_IP}:${APACHE_ADMIN_PORT}/ connectiontimeout=5 timeout=300
    ProxyPassReverse / http://${APACHE_BACKEND_IP}:${APACHE_ADMIN_PORT}/
</VirtualHost>
PANELEOF
            ;;
    esac

    apachectl configtest
    __log "ISPConfig panel configured at https://${PANEL_HOSTNAME}/"
}

# ── Apache SSL assets ─────────────────────────────────────────────────────────
__configure_ssl() {
    __log "Preparing Apache SSL assets..."
    mkdir -p "$SSL_DIR"
    if [[ -n "${ISPCONFIG_PANEL_CERT:-}${ISPCONFIG_PANEL_KEY:-}" ]]; then
        [[ -f "$PANEL_CERT_FILE" && -f "$PANEL_KEY_FILE" ]] \
            || __error "ISPCONFIG_PANEL_CERT and ISPCONFIG_PANEL_KEY must both name readable files"
    elif [[ ! -f "$PANEL_CERT_FILE" || ! -f "$PANEL_KEY_FILE" ]]; then
        local cert_extensions=()
        if openssl req -help 2>&1 | grep -q -- '-addext'; then
            cert_extensions=(-addext "subjectAltName=DNS:${PANEL_HOSTNAME}")
        fi
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$PANEL_KEY_FILE" -out "$PANEL_CERT_FILE" \
            -subj "/C=US/ST=./L=./O=ISPConfig/CN=${PANEL_HOSTNAME}" \
            "${cert_extensions[@]}"
    fi
    if [[ ! -f "${SSL_DIR}/default.crt" || ! -f "${SSL_DIR}/default.key" ]]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "${SSL_DIR}/default.key" -out "${SSL_DIR}/default.crt" \
            -subj "/C=US/ST=./L=./O=Default/CN=${HOSTNAME}"
    fi
    chmod 640 "${SSL_DIR}"/*.key 2>/dev/null || true

    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/99-ispconfig-apache-reload <<'HOOKEOF'
#!/bin/bash
if apachectl configtest; then
    if systemctl reload apache2 2>/dev/null; then
        exit 0
    fi
    systemctl reload httpd
fi
HOOKEOF
    chmod 750 /etc/letsencrypt/renewal-hooks/deploy/99-ispconfig-apache-reload
    __log "Apache SSL certificate paths: ${PANEL_CERT_FILE}, ${PANEL_KEY_FILE}"
}

# ── Final configuration ───────────────────────────────────────────────────────
# ── amavisd repair ─────────────────────────────────────────────────────────────
# RHEL-family and SUSE ship /etc/amavisd + amavisd.service; Debian-family ship
# /etc/amavis + amavis.service. Sets AMAVIS_CONF_DIR/AMAVIS_SERVICE, or leaves
# AMAVIS_CONF_DIR empty when amavis is not installed.
AMAVIS_CONF_DIR=""
AMAVIS_SERVICE=""
__amavis_detect() {
    AMAVIS_CONF_DIR=""
    if [[ -d /etc/amavisd ]]; then
        AMAVIS_CONF_DIR="/etc/amavisd"
        AMAVIS_SERVICE="amavisd"
    elif [[ -d /etc/amavis ]]; then
        AMAVIS_CONF_DIR="/etc/amavis"
        AMAVIS_SERVICE="amavis"
    fi
}

__fixup_amavisd() {
    # amavisd is optional; nothing to do when the package is absent.
    __amavis_detect
    [[ -n "$AMAVIS_CONF_DIR" ]] || return 0

    __log "Repairing amavisd installation..."

    # 1. Missing Perl DBI driver. The amavis RPM does not pull perl-DBD-mysql in,
    #    and amavisd hard-exits with "MISSING REQUIRED ADDITIONAL MODULES"
    #    before it ever binds a socket.
    if ! perl -MDBD::mysql -e1 2>/dev/null; then
        local dbd_pkgs="perl-DBI perl-DBD-mysql"
        [[ "$PACKAGE_MANAGER" == "apt" ]] && dbd_pkgs="libdbi-perl libdbd-mysql-perl"
        # shellcheck disable=SC2086
        __try_install "$PACKAGE_MANAGER" $dbd_pkgs \
            || __warn "amavisd: perl DBD::mysql unavailable — amavisd will not start"
    fi

    # 2. ISPConfig's installer_base.lib.php chmods amavisd.conf and 60-dkim to
    #    0640 but leaves the group as root. amavisd drops to $daemon_user
    #    (amavis), so it falls into the "other" class and gets EACCES on its
    #    own config. Restore group-read for the amavis group across the tree.
    chgrp -R amavis "$AMAVIS_CONF_DIR" 2>/dev/null || true
    find "$AMAVIS_CONF_DIR" -type f -exec chmod g+r,o-r {} + 2>/dev/null || true

    # 3. SELinux: amavisd runs as antivirus_exec_t but ports 10026/10027 ship
    #    as spamd_port_t, so it cannot bind its own nanny port and dies with
    #    "Can't connect to TCP port 10026 on 127.0.0.1 [Permission denied]".
    #    10024 already carries amavisd_recv_port_t.
    if command -v semanage >/dev/null 2>&1; then
        local p
        for p in 10026 10027; do
            semanage port -a -t amavisd_recv_port_t -p tcp "$p" 2>/dev/null \
                || semanage port -m -t amavisd_recv_port_t -p tcp "$p" 2>/dev/null || true
        done
        restorecon -R "$AMAVIS_CONF_DIR" 2>/dev/null || true
    fi

    # 3b. The amavis transport hands mail to amavisd over plain SMTP on
    #     127.0.0.1:10024. A global smtp_tls_wrappermode=yes (from a base config)
    #     would make Postfix attempt TLS on that port and defer all mail.
    if postconf -M amavis/unix >/dev/null 2>&1; then
        if ! postconf -P "amavis/unix/smtp_tls_wrappermode=no" \
                "amavis/unix/smtp_tls_security_level=none" >/dev/null 2>&1; then
            local master_cf=/etc/postfix/master.cf
            local master_cf_tmp
            master_cf_tmp=$(mktemp "${master_cf}.XXXXXX")
            if awk '
                function flush_amavis() {
                    if (!wrapper) print "  -o smtp_tls_wrappermode=no"
                    if (!security) print "  -o smtp_tls_security_level=none"
                }
                /^[[:space:]]*#/ { print; next }
                /^[^[:space:]]/ {
                    if (in_amavis) flush_amavis()
                    in_amavis = ($1 == "amavis" && $2 == "unix")
                    if (in_amavis) found = 1
                    wrapper = 0
                    security = 0
                    print
                    next
                }
                in_amavis && /^[[:space:]]+-o[[:space:]]+smtp_tls_wrappermode[[:space:]]*=/ {
                    print "  -o smtp_tls_wrappermode=no"
                    wrapper = 1
                    next
                }
                in_amavis && /^[[:space:]]+-o[[:space:]]+smtp_tls_security_level[[:space:]]*=/ {
                    print "  -o smtp_tls_security_level=none"
                    security = 1
                    next
                }
                { print }
                END {
                    if (in_amavis) flush_amavis()
                    if (!found) exit 42
                }
            ' "$master_cf" > "$master_cf_tmp"; then
                chown --reference="$master_cf" "$master_cf_tmp"
                chmod --reference="$master_cf" "$master_cf_tmp"
                mv -f "$master_cf_tmp" "$master_cf"
            else
                rm -f "$master_cf_tmp"
                __error "Could not set TLS overrides for the amavis Postfix transport"
            fi
        fi
        postfix reload
    fi

    # 4. The package ships disabled, so on a real reboot amavisd never comes up
    #    and Postfix's content_filter points at a dead port.
    systemctl enable "$AMAVIS_SERVICE" 2>/dev/null || true
    systemctl reset-failed "$AMAVIS_SERVICE" 2>/dev/null || true
    systemctl restart "$AMAVIS_SERVICE" 2>/dev/null \
        || __warn "${AMAVIS_SERVICE} failed to start — check: journalctl -u ${AMAVIS_SERVICE}"

    __success "amavisd configuration repaired"
}

__final_configuration() {
    __log "Performing final configuration..."

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

    # Apache serves website and panel traffic directly on ports 80 and 443.
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
    __fixup_amavisd
    apachectl configtest

    # Verify the stack actually came up. A service that failed to start leaves
    # the machine unusable but every step above still reports [OK], because the
    # restarts are masked with "2>/dev/null || true". Check explicitly and fail
    # the step rather than handing the operator a green summary.
    __verify_services

    __create_php_test_script
}

# Assert every service this installer depends on is actually running, and that
# the panel answers. A non-zero exit fails the calling __step.
__verify_services() {
    local failed=() svc

    for svc in "${APACHE_SERVICE}" postfix; do
        systemctl is-active --quiet "$svc" || failed+=("$svc")
    done

    # amavisd only when the package is present. Postfix's content_filter points
    # at 127.0.0.1:10024, so a dead amavisd silently breaks the mail path.
    __amavis_detect
    if [[ -n "$AMAVIS_CONF_DIR" ]]; then
        systemctl is-active --quiet "$AMAVIS_SERVICE" || failed+=("$AMAVIS_SERVICE")
    fi

    # Every Postfix MySQL map must answer a lookup (exit 0 = hit, 1 = no match);
    # anything else means the DB grant or credentials are wrong and mail defers.
    local map rc
    for map in /etc/postfix/mysql-*.cf; do
        [[ -f "$map" ]] || continue
        rc=0
        postmap -q "probe@verify.invalid" "mysql:${map}" >/dev/null 2>&1 || rc=$?
        ((rc <= 1)) || failed+=("postfix-map:${map##*/}")
    done

    if ((${#failed[@]} > 0)); then
        __error "Service(s) not running after install: ${failed[*]}"
        for svc in "${failed[@]}"; do
            __log "--- systemctl status ${svc} ---"
            systemctl status "$svc" --no-pager --lines=5 2>&1 | head -8 || true
        done
        return 1
    fi

    # The panel must answer through its hostname vhost on Apache TLS.
    local code
    code=$(curl -q -sk --resolve "${PANEL_HOSTNAME}:443:127.0.0.1" -o /dev/null \
        -w '%{http_code}' --max-time 20 "https://${PANEL_HOSTNAME}/" 2>/dev/null) || true
    code="${code:-000}"
    case "$code" in
        200|30[0-9]) __log "ISPConfig panel responding (HTTP ${code})" ;;
        *) __error "ISPConfig panel returned HTTP ${code} on https://${PANEL_HOSTNAME}/"; return 1 ;;
    esac

    if systemctl is-active --quiet nginx; then
        __error "Nginx is still active; Apache must be the only web listener"
        return 1
    fi
}

# ── Catch-all "no site" page ──────────────────────────────────────────────────
# Requests whose Host matches no configured site land on the first Apache vhost
# for the backend port. Make that vhost answer 404 with a friendly static page
# instead of the distro test page or another customer's site.
__configure_nosite_page() {
    local nosite_root="/var/www/ispconfig-nosite"
    local nosite_conf="${APACHE_VHOST_DIR}/00-ispconfig-nosite.conf"
    local main_config="" include_path=""
    case "$PACKAGE_MANAGER" in
        apt) ;;
        zypper)
            nosite_conf="${APACHE_CONF_DIR}/ispconfig-nosite.conf"
            main_config="${APACHE_CONF_DIR}/httpd.conf"
            include_path="$nosite_conf"
            ;;
        *)
            nosite_conf="${APACHE_CONF_DIR}/conf/ispconfig-nosite.conf"
            main_config="${APACHE_CONF_DIR}/conf/httpd.conf"
            include_path="conf/ispconfig-nosite.conf"
            ;;
    esac

    mkdir -p "$nosite_root" "${LETSENCRYPT_WEBROOT}/.well-known/acme-challenge"
    chmod 755 "${LETSENCRYPT_WEBROOT}" "${LETSENCRYPT_WEBROOT}/.well-known" \
        "${LETSENCRYPT_WEBROOT}/.well-known/acme-challenge"
    cat > "${nosite_root}/nosite.html" << 'NOSITE_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="color-scheme" content="dark light">
<title>No site at this address</title>
<style>
:root {
  --bg: #282a36;
  --bg-elevated: #343746;
  --fg: #f8f8f2;
  --fg-muted: #c0c4d6;
  --accent: #bd93f9;
  --border: #44475a;
}
@media (prefers-color-scheme: light) {
  :root {
    --bg: #ffffff;
    --bg-elevated: #f6f8fa;
    --fg: #1f2328;
    --fg-muted: #57606a;
    --accent: #0969da;
    --border: #d0d7de;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 16px;
  background: var(--bg);
  color: var(--fg);
  font: 16px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
}
main {
  width: 100%;
  max-width: 34rem;
  padding: 2.5rem 2rem;
  background: var(--bg-elevated);
  border: 1px solid var(--border);
  border-radius: 12px;
  text-align: center;
}
.code {
  margin: 0;
  font-size: clamp(3.5rem, 18vw, 6rem);
  font-weight: 700;
  line-height: 1;
  letter-spacing: 0.04em;
  color: var(--accent);
}
h1 { margin: 1rem 0 0.75rem; font-size: 1.5rem; }
p { margin: 0 0 1rem; color: var(--fg-muted); }
hr { border: 0; border-top: 1px solid var(--border); margin: 1.5rem 0; }
.hint { margin: 0; font-size: 0.9rem; }
</style>
</head>
<body>
<main>
  <p class="code">404</p>
  <h1>No site at this address</h1>
  <p>This server is online, but no website has been set up for this domain name.</p>
  <hr>
  <p class="hint">Visitors: check the address for typos, or contact the site owner.</p>
  <p class="hint">Site owners: add this domain as a website in your hosting control panel and make sure its DNS records point to this server.</p>
</main>
</body>
</html>
NOSITE_EOF
    chown -R root:root "$nosite_root"
    chmod 755 "$nosite_root"
    chmod 644 "${nosite_root}/nosite.html"

    # Opt-in diagnostic page (ISPCONFIG_PHPINFO=1): let phpinfo.php through the
    # 404 rule and run it through the first php-fpm socket that exists. With no
    # socket it stays blocked rather than being served as plain text.
    local allowed_re='nosite\.html' php_handler="" sock
    NOSITE_PHPINFO=0
    if [[ "${ISPCONFIG_PHPINFO:-0}" == "1" ]]; then
        for sock in "/var/opt/remi/php${PHP_DEFAULT//./}/run/php-fpm/www.sock" \
                    "/run/php/php${PHP_DEFAULT}-fpm.sock" /run/php-fpm/www.sock; do
            [[ -S "$sock" ]] || continue
            [[ "$PACKAGE_MANAGER" == "apt" ]] && a2enmod proxy proxy_fcgi >/dev/null
            allowed_re='nosite\.html|phpinfo\.php'
            php_handler="    <Files \"phpinfo.php\">
        SetHandler \"proxy:unix:${sock}|fcgi://localhost\"
    </Files>"
            NOSITE_PHPINFO=1
            break
        done
        [[ $NOSITE_PHPINFO -eq 1 ]] || __warn "ISPCONFIG_PHPINFO=1 but no php-fpm socket found — phpinfo.php not enabled"
    fi
    __save_var NOSITE_PHPINFO

    cat > "$nosite_conf" <<NOSITE_VHOST_EOF
# Default HTTP vhost preserves ACME validation and redirects other requests.
<VirtualHost *:80>
    ServerName nosite.invalid
    DocumentRoot ${nosite_root}
    Alias /.well-known/acme-challenge/ ${LETSENCRYPT_WEBROOT}/.well-known/acme-challenge/
    <Directory ${LETSENCRYPT_WEBROOT}/.well-known/acme-challenge/>
        Require all granted
        Options None
        AllowOverride None
    </Directory>
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/.well-known/acme-challenge/
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L,NE]
</VirtualHost>

# Default HTTPS vhost answers 404 for hosts that do not match a site or panel.
<VirtualHost *:443>
    ServerName nosite.invalid
    DocumentRoot ${nosite_root}
    SSLEngine on
    SSLCertificateFile ${SSL_DIR}/default.crt
    SSLCertificateKeyFile ${SSL_DIR}/default.key
    ErrorDocument 404 /nosite.html
    RedirectMatch 404 "^/(?!(${allowed_re})\$)"
${php_handler}
    <Directory ${nosite_root}>
        Require all granted
        Options None
        AllowOverride None
    </Directory>
</VirtualHost>
NOSITE_VHOST_EOF

    case "$PACKAGE_MANAGER" in
        apt)
            a2dissite 000-default default-ssl 2>/dev/null || true
            a2ensite 00-ispconfig-nosite >/dev/null
            ;;
        *)
            if [[ -f "$main_config" ]]; then
                sed -i "\|^[[:space:]]*IncludeOptional ${include_path}[[:space:]]*$|d" "$main_config"
                local first_vhost first_vhost_include
                first_vhost_include=$(grep -n -m1 -E '^[[:space:]]*Include(Optional)?[[:space:]].*(conf\.d/|vhosts\.d/|sites-enabled/)' "$main_config" | cut -d: -f1)
                first_vhost=$(grep -n -m1 -E '^[[:space:]]*<VirtualHost([[:space:]]|>)' "$main_config" | cut -d: -f1)
                if [[ -n "$first_vhost_include" && ( -z "$first_vhost" || "$first_vhost_include" -lt "$first_vhost" ) ]]; then
                    first_vhost="$first_vhost_include"
                fi
                if [[ -n "$first_vhost" ]]; then
                    sed -i "${first_vhost}i IncludeOptional ${include_path}" "$main_config"
                else
                    printf '\nIncludeOptional %s\n' "$include_path" >> "$main_config"
                fi
            fi
            ;;
    esac

    apachectl configtest
    # Apache may not be running yet; __final_configuration starts it either way.
    if systemctl is-active --quiet "${APACHE_SERVICE}"; then
        systemctl reload "${APACHE_SERVICE}"
    fi
    __log "No-site catch-all page installed (${nosite_conf})"
}

__create_php_test_script() {
    local web_root="/var/www/ispconfig-nosite"

    # phpinfo() in a publicly reachable document root discloses the full PHP
    # build, loaded modules, environment and every *_PASSWD superglobal. It is
    # a diagnostic aid, not a default. Opt in with ISPCONFIG_PHPINFO=1.
    if [[ "${ISPCONFIG_PHPINFO:-0}" != "1" || "${NOSITE_PHPINFO:-0}" != "1" ]]; then
        rm -f "${web_root}/phpinfo.php"
        __log "phpinfo.php not created (set ISPCONFIG_PHPINFO=1 to enable)"
        return 0
    fi
    __warn "ISPCONFIG_PHPINFO=1 — phpinfo.php WILL be publicly reachable"

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
echo "<p>HTTPS: " . htmlspecialchars($_SERVER['HTTPS'] ?? 'off') . "</p>";
phpinfo();
EOF

    chown "${APACHE_USER}:${APACHE_USER}" "${web_root}/phpinfo.php" 2>/dev/null || true
    chmod 644 "${web_root}/phpinfo.php"
}

# ── Summary ───────────────────────────────────────────────────────────────────
__create_summary() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    cat > /root/ispconfig_installation_summary.txt <<EOF
ISPConfig Installation Summary — Apache Direct Architecture
===========================================================
Date:         $(date)
Distribution: ${DISTRO} ${DISTRO_VERSION}
Hostname:     ${HOSTNAME}
Server IP:    ${server_ip}

Architecture:
  Apache :80        → website vhosts, ACME challenge, HTTP to HTTPS redirect for unknown hosts
  Apache :443       → website vhosts, HTTPS catch-all 404, ISPConfig panel hostname
  Apache 127.0.0.1:${APACHE_ADMIN_PORT} → ISPConfig control panel backend

Credentials:
  ISPConfig panel:    https://${PANEL_HOSTNAME}/
  ISPConfig username: ${ISPCONFIG_ADMIN_USER}
  ISPConfig password: ${ISPCONFIG_ADMIN_PASSWORD}

  MySQL root user:    root
  MySQL root pass:    ${ISPCONFIG_MYSQL_ROOT_PASSWORD}

  ISPConfig DB user:  ispconfig
  ISPConfig DB pass:  ${ISPCONFIG_DB_PASSWORD}

SSL certificates (self-signed by default; replace with Let's Encrypt):
  Default:    ${SSL_DIR}/default.{crt,key}
  ISPConfig:  ${PANEL_CERT_FILE} and ${PANEL_KEY_FILE}
  Mail TLS:   /usr/local/ispconfig/interface/ssl/ispserver.{crt,key}

Mail server ports (the sysadmin must open these externally according to site policy):
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

Let's Encrypt:
  ACME webroot: ${LETSENCRYPT_WEBROOT}
  Apache reload deploy hook: /etc/letsencrypt/renewal-hooks/deploy/99-ispconfig-apache-reload
  Panel certificate paths: ${PANEL_CERT_FILE} and ${PANEL_KEY_FILE}

Important files:
  /usr/local/ispconfig/          ISPConfig root
  ${APACHE_CONF_DIR}/            Apache configuration
  ${APACHE_CONF_EXTRA}/ispconfig-panel.conf  Panel hostname vhost
  /etc/postfix/main.cf           Postfix config
  /etc/dovecot/conf.d/           Dovecot config
  /etc/opendkim.conf             OpenDKIM config
  /root/.my.cnf                  MySQL root credentials

Next steps:
  1. Point ${PANEL_HOSTNAME} to ${server_ip} and log in at https://${PANEL_HOSTNAME}/
  2. Replace the self-signed panel/default certificates with valid Let's Encrypt certificates
  3. Configure DKIM/SPF/DMARC DNS records (see above)
  4. Set reverse DNS (PTR) for your server IP with your VPS provider
  5. Configure hosted sites and certificates in ISPConfig
EOF

    chmod 0600 /root/ispconfig_installation_summary.txt
    __log "Summary saved to /root/ispconfig_installation_summary.txt"
}

# ── Main ──────────────────────────────────────────────────────────────────────
__main() {
    echo -e "${PURPLE}"
    echo "============================================"
    echo "  ISPConfig — Apache Direct Installer"
    echo "============================================"
    echo -e "${NC}"

    STATE_FILE=$(mktemp /tmp/ispconfig-state.XXXXXX)
    __check_root
    __check_existing_install
    __check_session_safety
    __detect_distro
    __generate_passwords
    __set_hostname

    __step "Updating system packages"          __update_system
    __step "Installing base packages"          __install_base_packages
    __step "Disabling existing Nginx"          __disable_nginx
    __step "Installing Apache"                 __install_apache
    __step "Installing MySQL/MariaDB"          __install_mysql
    __step "Installing PHP versions"           __install_php
    __step "Installing mail stack"             __install_mail
    __step "Installing FTP server"             __install_ftp
    __step "Installing tools"                  __install_tools
    __step "Installing fail2ban"               __install_fail2ban

    __step "Installing ISPConfig"              __install_ispconfig

    __step "Configuring Apache backend"        __configure_apache_backend
    __step "Applying SELinux policy"           __configure_selinux
    __step "Configuring SSL"                   __configure_ssl
    __step "Configuring Apache panel hostname" __configure_ispconfig_apache
    __step "Configuring public mail records"   __configure_mail_public

    __step "Installing no-site catch-all page" __configure_nosite_page
    __step "Finalizing configuration"          __final_configuration
    __create_summary

    # Print what was actually persisted, not the in-memory variables, so the
    # console can never advertise a credential the system did not take.
    local summary_file=/root/ispconfig_installation_summary.txt
    local admin_pass root_pass db_pass
    admin_pass=$(sed -n 's/^  ISPConfig password: //p' "${summary_file}")
    root_pass=$(sed -n 's/^  MySQL root pass: *//p' "${summary_file}")
    db_pass=$(sed -n 's/^  ISPConfig DB pass: *//p' "${summary_file}")
    if [[ -z "$admin_pass" || -z "$root_pass" || -z "$db_pass" ]]; then
        __error "Could not read credentials back from ${summary_file}"
    fi
    local mysql_bin="mysql"
    command -v mariadb >/dev/null 2>&1 && mysql_bin="mariadb"
    if ! "${mysql_bin}" -u root -p"${root_pass}" -e 'SELECT 1' >/dev/null 2>&1; then
        __error "The MySQL root password in ${summary_file} does not authenticate"
    fi
    __success "Credentials in ${summary_file} verified against the live system"

    echo -e "${GREEN}"
    __log "============================================"
    __log "Installation complete!"
    __log "============================================"
    echo -e "${NC}"
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
    __log "ISPConfig panel:    https://${PANEL_HOSTNAME}/"
    __log "ISPConfig username: ${ISPCONFIG_ADMIN_USER}"
    __log "ISPConfig password: ${admin_pass}"
    __log "MySQL root user:    root"
    __log "MySQL root pass:    ${root_pass}"
    __log "ISPConfig DB user:  ispconfig"
    __log "ISPConfig DB pass:  ${db_pass}"
    __warn "Credentials saved to: /root/ispconfig_installation_summary.txt"
    echo -e "${NC}"
    rm -f "$STATE_FILE"
}

__main "$@"
