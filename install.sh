#!/bin/bash

# Universal ISPConfig Installation Script
# Supports all ISPConfig-compatible Linux distributions
# Run as root: bash ispconfig_universal_installer.sh

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Global variables
ADMIN_PORT=64245
MYSQL_ROOT_PASSWORD=""
ISPCONFIG_DB_PASSWORD=""
HOSTNAME=""
DISTRO=""
DISTRO_VERSION=""
PACKAGE_MANAGER=""
SERVICE_MANAGER="systemctl"
PHP_VERSIONS=("5.6" "7.0" "7.1" "7.2" "7.3" "7.4" "8.0" "8.1" "8.2" "8.3")

# Logging functions
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

success() {
    echo -e "${BLUE}[SUCCESS]${NC} $1"
}

# Check if running as root
__check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

# Detect Linux distribution
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
        if grep -q "CentOS" /etc/redhat-release; then
            DISTRO="centos"
        elif grep -q "Red Hat" /etc/redhat-release; then
            DISTRO="rhel"
        elif grep -q "AlmaLinux" /etc/redhat-release; then
            DISTRO="almalinux"
        elif grep -q "Rocky" /etc/redhat-release; then
            DISTRO="rocky"
        fi
        DISTRO_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
    else
        error "Cannot detect Linux distribution"
    fi
    
    log "Detected: $DISTRO $DISTRO_VERSION"
    
    # Validate supported distributions
    __validate_distro
}

# Validate if distribution is supported by ISPConfig
__validate_distro() {
    local supported=false
    
    case "$DISTRO" in
        "ubuntu")
            if [[ "$DISTRO_VERSION" =~ ^(18|20|22|24) ]]; then
                supported=true
                PACKAGE_MANAGER="apt"
            fi
            ;;
        "debian")
            if [[ "$DISTRO_VERSION" =~ ^(9|10|11|12) ]]; then
                supported=true
                PACKAGE_MANAGER="apt"
            fi
            ;;
        "centos"|"rhel")
            if [[ "$DISTRO_VERSION" =~ ^(7|8|9) ]]; then
                supported=true
                PACKAGE_MANAGER="yum"
                [[ "$DISTRO_VERSION" =~ ^(8|9) ]] && PACKAGE_MANAGER="dnf"
            fi
            ;;
        "almalinux"|"rocky")
            if [[ "$DISTRO_VERSION" =~ ^(8|9|10) ]]; then
                supported=true
                PACKAGE_MANAGER="dnf"
            fi
            ;;
        "fedora")
            if [[ "$DISTRO_VERSION" =~ ^(3[6-9]|4[0-9]) ]]; then
                supported=true
                PACKAGE_MANAGER="dnf"
            fi
            ;;
        "opensuse"|"opensuse-leap"|"sles")
            if [[ "$DISTRO_VERSION" =~ ^(15|42) ]]; then
                supported=true
                PACKAGE_MANAGER="zypper"
            fi
            ;;
    esac
    
    if [[ "$supported" != "true" ]]; then
        error "Unsupported distribution: $DISTRO $DISTRO_VERSION
Supported distributions:
- Ubuntu: 18.04, 20.04, 22.04, 24.04
- Debian: 9, 10, 11, 12
- CentOS/RHEL: 7, 8, 9
- AlmaLinux/Rocky: 8, 9, 10
- Fedora: 36-49
- openSUSE Leap: 15.x"
    fi
    
    success "Distribution $DISTRO $DISTRO_VERSION is supported"
    log "Package manager: $PACKAGE_MANAGER"
}

# Generate secure passwords
__generate_passwords() {
    if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
        MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)
        log "Generated MySQL root password"
    fi
    
    if [[ -z "$ISPCONFIG_DB_PASSWORD" ]]; then
        ISPCONFIG_DB_PASSWORD=$(openssl rand -base64 32)
        log "Generated ISPConfig database password"
    fi
}

# Set hostname if not already set
__set_hostname() {
    if [[ -z "$HOSTNAME" ]]; then
        HOSTNAME="server.$(hostname -d 2>/dev/null || echo 'local')"
        warn "Setting hostname to: $HOSTNAME"
        hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || echo "$HOSTNAME" > /etc/hostname
    fi
}

# Update system packages
__update_system() {
    log "Updating system packages..."
    
    case "$PACKAGE_MANAGER" in
        "apt")
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get upgrade -y
            apt-get install -y software-properties-common apt-transport-https ca-certificates
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

# Install base packages
__install_base_packages() {
    log "Installing base packages..."
    
    local base_packages="wget curl nano vim net-tools bind-utils openssl"
    
    case "$PACKAGE_MANAGER" in
        "apt")
            apt-get install -y $base_packages dnsutils
            ;;
        "dnf"|"yum")
            $PACKAGE_MANAGER install -y $base_packages
            ;;
        "zypper")
            zypper install -y $base_packages bind-utils
            ;;
    esac
}

# Configure firewall
__configure_firewall() {
    log "Configuring firewall..."
    
    case "$DISTRO" in
        "ubuntu"|"debian")
            # Install and configure UFW
            if ! command -v ufw &> /dev/null; then
                apt-get install -y ufw
            fi
            
            ufw --force enable
            ufw allow ssh
            ufw allow http
            ufw allow https
            ufw allow ftp
            ufw allow 21/tcp
            ufw allow 49152:65534/tcp
            ufw allow 25/tcp   # SMTP
            ufw allow 110/tcp  # POP3
            ufw allow 143/tcp  # IMAP
            ufw allow 465/tcp  # SMTPS
            ufw allow 993/tcp  # IMAPS
            ufw allow 995/tcp  # POP3S
            ufw allow 53/tcp   # DNS
            ufw allow 53/udp   # DNS
            ufw allow $ADMIN_PORT/tcp
            ufw allow 3306/tcp # MySQL
            ;;
        *)
            # Configure firewalld for RHEL-based and others
            if command -v firewalld &> /dev/null; then
                systemctl enable firewalld
                systemctl start firewalld
                
                firewall-cmd --permanent --add-service=http
                firewall-cmd --permanent --add-service=https
                firewall-cmd --permanent --add-service=ssh
                firewall-cmd --permanent --add-service=ftp
                firewall-cmd --permanent --add-port=21/tcp
                firewall-cmd --permanent --add-port=49152-65534/tcp
                firewall-cmd --permanent --add-service=smtp
                firewall-cmd --permanent --add-service=pop3
                firewall-cmd --permanent --add-service=imap
                firewall-cmd --permanent --add-service=smtps
                firewall-cmd --permanent --add-service=pop3s
                firewall-cmd --permanent --add-service=imaps
                firewall-cmd --permanent --add-service=dns
                firewall-cmd --permanent --add-port=${ADMIN_PORT}/tcp
                firewall-cmd --permanent --add-port=3306/tcp
                firewall-cmd --reload
            fi
            ;;
    esac
}

# Install and configure Apache
__install_apache() {
    log "Installing Apache web server..."
    
    case "$PACKAGE_MANAGER" in
        "apt")
            apt-get install -y apache2 apache2-utils libapache2-mod-fcgid
            a2enmod rewrite ssl fcgid
            systemctl enable apache2
            systemctl start apache2
            ;;
        "dnf"|"yum")
            $PACKAGE_MANAGER install -y httpd mod_ssl mod_fcgid
            systemctl enable httpd
            systemctl start httpd
            ;;
        "zypper")
            zypper install -y apache2 apache2-mod_fcgid apache2-mod_ssl
            systemctl enable apache2
            systemctl start apache2
            ;;
    esac
}

# Install and configure MySQL/MariaDB
__install_mysql() {
    log "Installing MariaDB server..."
    
    case "$PACKAGE_MANAGER" in
        "apt")
            apt-get install -y mariadb-server mariadb-client
            ;;
        "dnf"|"yum")
            $PACKAGE_MANAGER install -y mariadb-server mariadb
            ;;
        "zypper")
            zypper install -y mariadb mariadb-client
            ;;
    esac
    
    systemctl enable mariadb
    systemctl start mariadb
    
    log "Securing MariaDB installation..."
    # Set root password and secure installation
    mysql -e "UPDATE mysql.user SET Password = PASSWORD('$MYSQL_ROOT_PASSWORD') WHERE User = 'root'" 2>/dev/null || \
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD'"
    mysql -e "DELETE FROM mysql.user WHERE User=''"
    mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1')"
    mysql -e "DROP DATABASE IF EXISTS test"
    mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'"
    mysql -e "FLUSH PRIVILEGES"
    
    # Create MySQL config file for root
    cat > /root/.my.cnf << EOF
[client]
user=root
password=$MYSQL_ROOT_PASSWORD
EOF
    chmod 600 /root/.my.cnf
}

# Install multiple PHP versions
__install_php() {
    log "Installing multiple PHP versions..."
    
    case "$DISTRO" in
        "ubuntu"|"debian")
            __install_php_debian
            ;;
        "centos"|"rhel"|"almalinux"|"rocky"|"fedora")
            __install_php_rhel
            ;;
        "opensuse"|"opensuse-leap"|"sles")
            __install_php_suse
            ;;
    esac
    
    __configure_php_versions
}

# Install PHP on Debian/Ubuntu systems
__install_php_debian() {
    log "Installing PHP on Debian/Ubuntu system..."
    
    # Add Ondrej PHP repository
    if [[ "$DISTRO" == "ubuntu" ]]; then
        add-apt-repository -y ppa:ondrej/php
    else
        # Debian
        wget -qO /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
        echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
    fi
    
    apt-get update
    
    # Install PHP versions with common extensions
    for version in "${PHP_VERSIONS[@]}"; do
        log "Installing PHP $version..."
        version_clean=${version//./}
        
        apt-get install -y \
            php${version} \
            php${version}-cli \
            php${version}-fpm \
            php${version}-mysql \
            php${version}-mysqli \
            php${version}-gd \
            php${version}-mbstring \
            php${version}-xml \
            php${version}-curl \
            php${version}-zip \
            php${version}-soap \
            php${version}-intl \
            php${version}-bcmath \
            php${version}-opcache \
            php${version}-json 2>/dev/null || warn "Some PHP $version packages failed to install"
        
        # Enable and start PHP-FPM
        systemctl enable php${version}-fpm 2>/dev/null || true
        systemctl start php${version}-fpm 2>/dev/null || true
    done
    
    # Set PHP 8.1 as default
    update-alternatives --set php /usr/bin/php8.1 2>/dev/null || true
}

# Install PHP on RHEL-based systems
__install_php_rhel() {
    log "Installing PHP on RHEL-based system..."
    
    # Install Remi repository
    case "$DISTRO_VERSION" in
        7*) 
            $PACKAGE_MANAGER install -y https://rpms.remirepo.net/enterprise/remi-release-7.rpm
            ;;
        8*) 
            $PACKAGE_MANAGER install -y https://rpms.remirepo.net/enterprise/remi-release-8.rpm
            ;;
        9*) 
            $PACKAGE_MANAGER install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
            ;;
        *) 
            # Try to detect major version
            major_version=$(echo "$DISTRO_VERSION" | cut -d. -f1)
            $PACKAGE_MANAGER install -y https://rpms.remirepo.net/enterprise/remi-release-${major_version}.rpm
            ;;
    esac
    
    # Install PHP versions
    for version in "${PHP_VERSIONS[@]}"; do
        version_clean=${version//./}
        log "Installing PHP $version..."
        
        $PACKAGE_MANAGER install -y --enablerepo=remi \
            php${version_clean} \
            php${version_clean}-php-cli \
            php${version_clean}-php-fpm \
            php${version_clean}-php-mysql \
            php${version_clean}-php-mysqli \
            php${version_clean}-php-gd \
            php${version_clean}-php-mbstring \
            php${version_clean}-php-xml \
            php${version_clean}-php-curl \
            php${version_clean}-php-zip \
            php${version_clean}-php-soap \
            php${version_clean}-php-intl \
            php${version_clean}-php-bcmath \
            php${version_clean}-php-opcache \
            php${version_clean}-php-json 2>/dev/null || warn "Some PHP $version packages failed to install"
        
        # Enable and start PHP-FPM
        systemctl enable php${version_clean}-php-fpm 2>/dev/null || true
        systemctl start php${version_clean}-php-fpm 2>/dev/null || true
        
        # Create symlinks
        ln -sf /opt/remi/php${version_clean}/root/usr/bin/php /usr/local/bin/php${version} 2>/dev/null || true
    done
    
    # Set PHP 8.1 as default
    alternatives --install /usr/bin/php php /opt/remi/php81/root/usr/bin/php 81 2>/dev/null || true
}

# Install PHP on openSUSE/SLES
__install_php_suse() {
    log "Installing PHP on openSUSE/SLES system..."
    
    # Install available PHP versions (typically fewer than other distros)
    local available_versions=("7.4" "8.0" "8.1" "8.2")
    
    for version in "${available_versions[@]}"; do
        log "Installing PHP $version..."
        version_clean=${version//./}
        
        zypper install -y \
            php${version_clean} \
            php${version_clean}-cli \
            php${version_clean}-fpm \
            php${version_clean}-mysql \
            php${version_clean}-gd \
            php${version_clean}-mbstring \
            php${version_clean}-xml \
            php${version_clean}-curl \
            php${version_clean}-zip \
            php${version_clean}-soap \
            php${version_clean}-intl \
            php${version_clean}-bcmath \
            php${version_clean}-opcache 2>/dev/null || warn "Some PHP $version packages failed to install"
        
        systemctl enable php-fpm 2>/dev/null || true
        systemctl start php-fpm 2>/dev/null || true
    done
}

# Configure PHP settings for all versions
__configure_php_versions() {
    log "Configuring PHP settings for all versions..."
    
    # Find all PHP configuration files
    for php_ini in $(find /etc -name "php.ini" 2>/dev/null); do
        log "Configuring $php_ini..."
        
        # Update PHP configuration
        sed -i 's/;date.timezone =/date.timezone = UTC/' "$php_ini"
        sed -i 's/upload_max_filesize = 2M/upload_max_filesize = 100M/' "$php_ini"
        sed -i 's/post_max_size = 8M/post_max_size = 100M/' "$php_ini"
        sed -i 's/max_execution_time = 30/max_execution_time = 300/' "$php_ini"
        sed -i 's/memory_limit = 128M/memory_limit = 256M/' "$php_ini"
        sed -i 's/max_input_vars = 1000/max_input_vars = 10000/' "$php_ini"
        sed -i 's/;log_errors = On/log_errors = On/' "$php_ini"
    done
}

# Install mail services
__install_mail() {
    log "Installing mail services..."
    
    case "$PACKAGE_MANAGER" in
        "apt")
            apt-get install -y postfix dovecot-core dovecot-imapd dovecot-pop3d dovecot-mysql dovecot-sieve dovecot-lmtpd
            ;;
        "dnf"|"yum")
            $PACKAGE_MANAGER install -y postfix dovecot dovecot-mysql dovecot-pigeonhole
            ;;
        "zypper")
            zypper install -y postfix dovecot dovecot-backend-mysql
            ;;
    esac
    
    systemctl enable postfix dovecot
    systemctl start postfix dovecot
}

# Install FTP server
__install_ftp() {
    log "Installing Pure-FTPd..."
    
    case "$PACKAGE_MANAGER" in
        "apt")
            apt-get install -y pure-ftpd-common pure-ftpd-mysql
            ;;
        "dnf"|"yum")
            $PACKAGE_MANAGER install -y pure-ftpd
            ;;
        "zypper")
            zypper install -y pure-ftpd
            ;;
    esac
    
    systemctl enable pure-ftpd
    systemctl start pure-ftpd
}

# Install additional tools
__install_tools() {
    log "Installing additional tools..."
    
    case "$PACKAGE_MANAGER" in
        "apt")
            apt-get install -y awstats webalizer bind9 bind9utils clamav clamav-daemon amavisd-new spamassassin rsync cron quota
            ;;
        "dnf"|"yum")
            $PACKAGE_MANAGER install -y awstats webalizer bind bind-utils clamav clamav-update amavisd-new spamassassin rsync crontabs quota
            ;;
        "zypper")
            zypper install -y awstats webalizer bind bind-utils clamav amavisd-new spamassassin rsync cron quota
            ;;
    esac
}

# Download and install ISPConfig
__install_ispconfig() {
    log "Downloading ISPConfig..."
    cd /tmp
    wget -O ispconfig.tar.gz https://www.ispconfig.org/downloads/ISPConfig-3-stable.tar.gz
    tar xfz ispconfig.tar.gz
    cd ispconfig3*/install/
    
    log "Starting ISPConfig installation..."
    
    # Create automated installation answers
    cat > /tmp/ispconfig_answers.txt << EOF
Select language (en,de): en
Installation mode (standard,expert): expert
Full qualified hostname (FQDN) of the server: $HOSTNAME
MySQL server hostname: localhost
MySQL server port: 3306
MySQL root username: root
MySQL root password: $MYSQL_ROOT_PASSWORD
MySQL database to create: dbispconfig
MySQL charset: utf8
Configure Mail (y,n): y
Configure Jailkit (y,n): y
Configure FTP Server (y,n): y
Configure DNS Server (y,n): y
Configure Apache Web Server (y,n): y
Configure Firewall (y,n): n
ISPConfig Port: $ADMIN_PORT
Admin password: $ISPCONFIG_DB_PASSWORD
Do you want a secure (SSL) connection to the ISPConfig web interface (y,n): y
Country Name: US
State or Province Name: 
Locality Name: 
Organization Name: ISPConfig
Organizational Unit Name: 
Common Name: $HOSTNAME
Email Address: admin@$HOSTNAME
EOF

    # Run ISPConfig installer
    php install.php --autoinstall=/tmp/ispconfig_answers.txt
}

# Configure SSL certificate for ISPConfig
__configure_ssl() {
    log "Configuring SSL certificate for ISPConfig admin panel..."
    
    # Generate self-signed certificate if not exists
    if [[ ! -f /usr/local/ispconfig/interface/ssl/ispserver.crt ]]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout /usr/local/ispconfig/interface/ssl/ispserver.key \
            -out /usr/local/ispconfig/interface/ssl/ispserver.crt \
            -subj "/C=US/ST=/L=/O=ISPConfig/OU=/CN=$HOSTNAME/emailAddress=admin@$HOSTNAME"
    fi
}

# Final system configuration
__final_configuration() {
    log "Performing final configuration..."
    
    # Restart all services based on distro
    case "$DISTRO" in
        "ubuntu"|"debian")
            systemctl restart apache2 mariadb postfix dovecot pure-ftpd
            systemctl enable apache2 mariadb postfix dovecot pure-ftpd
            
            # Restart PHP-FPM services
            for version in "${PHP_VERSIONS[@]}"; do
                systemctl restart php${version}-fpm 2>/dev/null || true
                systemctl enable php${version}-fpm 2>/dev/null || true
            done
            ;;
        *)
            systemctl restart httpd mariadb postfix dovecot pure-ftpd
            systemctl enable httpd mariadb postfix dovecot pure-ftpd
            
            # Restart PHP-FPM services for RHEL-based
            for version in "${PHP_VERSIONS[@]}"; do
                version_clean=${version//./}
                systemctl restart php${version_clean}-php-fpm 2>/dev/null || true
                systemctl enable php${version_clean}-php-fpm 2>/dev/null || true
            done
            ;;
    esac
    
    # Set up log rotation
    cat > /etc/logrotate.d/ispconfig << EOF
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

    __create_php_test_script
}

# Create PHP version test script
__create_php_test_script() {
    log "Creating PHP version test script..."
    
    local web_root="/var/www/html"
    [[ "$DISTRO" =~ ^(opensuse|sles) ]] && web_root="/srv/www/htdocs"
    
    cat > ${web_root}/phpinfo.php << 'EOF'
<?php
echo "<h1>Server PHP Information</h1>";
echo "<h2>Distribution: " . php_uname('s') . " " . php_uname('r') . "</h2>";
echo "<h2>Available PHP Versions:</h2>";
echo "<ul>";

// Check common PHP binary locations
$php_locations = [
    '/usr/bin/',
    '/usr/local/bin/',
    '/opt/remi/php*/root/usr/bin/'
];

$found_versions = [];
foreach (glob('/usr/bin/php*') as $php_bin) {
    if (preg_match('/php(\d+\.\d+)$/', $php_bin, $matches)) {
        $version = $matches[1];
        $output = shell_exec($php_bin . ' -v 2>&1');
        if ($output && strpos($output, 'PHP') !== false) {
            $found_versions[$version] = $php_bin;
        }
    }
}

// Check Remi locations for RHEL-based systems
foreach (glob('/opt/remi/php*/root/usr/bin/php') as $php_bin) {
    if (preg_match('/php(\d+)/', $php_bin, $matches)) {
        $version_num = $matches[1];
        $version = substr($version_num, 0, 1) . '.' . substr($version_num, 1);
        $output = shell_exec($php_bin . ' -v 2>&1');
        if ($output && strpos($output, 'PHP') !== false) {
            $found_versions[$version] = $php_bin;
        }
    }
}

ksort($found_versions);
foreach ($found_versions as $version => $path) {
    echo "<li><strong>PHP $version:</strong> Available at $path</li>";
}

echo "</ul>";
echo "<h2>Current PHP Version (default):</h2>";
phpinfo();
?>
EOF

    chown www-data:www-data ${web_root}/phpinfo.php 2>/dev/null || \
    chown apache:apache ${web_root}/phpinfo.php 2>/dev/null || \
    chown wwwrun:www ${web_root}/phpinfo.php 2>/dev/null || true
    chmod 644 ${web_root}/phpinfo.php
}

# Create installation summary
__create_summary() {
    cat > /root/ispconfig_installation_summary.txt << EOF
ISPConfig Universal Installation Summary
=======================================

Installation Date: $(date)
Distribution: $DISTRO $DISTRO_VERSION
Package Manager: $PACKAGE_MANAGER
Hostname: $HOSTNAME

Access Information:
- ISPConfig Admin Panel: https://$HOSTNAME:$ADMIN_PORT
- ISPConfig Admin Panel (IP): https://$(hostname -I | awk '{print $1}'):$ADMIN_PORT
- Admin Username: admin
- Admin Password: $ISPCONFIG_DB_PASSWORD

MySQL Information:
- Root Password: $MYSQL_ROOT_PASSWORD
- ISPConfig DB Password: $ISPCONFIG_DB_PASSWORD

PHP Versions Installed:
EOF

    # Add detected PHP versions to summary
    for version in "${PHP_VERSIONS[@]}"; do
        if command -v php${version} &> /dev/null || [[ -f /usr/local/bin/php${version} ]]; then
            echo "- PHP $version: Available" >> /root/ispconfig_installation_summary.txt
        fi
    done

    cat >> /root/ispconfig_installation_summary.txt << EOF

Important Files:
- ISPConfig Config: /usr/local/ispconfig/server/lib/config.inc.php
- Web Server Config: /etc/apache2/ or /etc/httpd/
- MySQL Config: /etc/mysql/ or /etc/my.cnf
- PHP Configs: /etc/php/ or /etc/opt/remi/

Log Files:
- ISPConfig Logs: /var/log/ispconfig/
- Web Server Logs: /var/log/apache2/ or /var/log/httpd/
- MySQL Logs: /var/log/mysql/ or /var/log/mariadb/

Test Pages:
- PHP Info: http://$HOSTNAME/phpinfo.php

Next Steps:
1. Access the admin panel at https://$HOSTNAME:$ADMIN_PORT
2. Log in with username 'admin' and the password above
3. Configure your first website and email accounts
4. Select PHP versions per website in ISPConfig
5. Consider setting up Let's Encrypt for production SSL certificates

Security Notes:
- Change default passwords after first login
- Configure proper backup procedures
- Keep the system updated regularly
- Review firewall settings for your specific needs
- Remove or secure the phpinfo.php file in production

Distribution-Specific Notes:
EOF

    case "$DISTRO" in
        "ubuntu"|"debian")
            cat >> /root/ispconfig_installation_summary.txt << EOF
- Web root: /var/www/html
- Service management: systemctl
- Firewall: UFW configured
- PHP-FPM services: php{version}-fpm
EOF
            ;;
        *)
            cat >> /root/ispconfig_installation_summary.txt << EOF
- Web root: /var/www/html
- Service management: systemctl
- Firewall: firewalld configured
- PHP-FPM services: php{version}-php-fpm
EOF
            ;;
    esac

    cat >> /root/ispconfig_installation_summary.txt << EOF

For support, visit: https://www.ispconfig.org/documentation/
EOF

    log "Installation summary saved to: /root/ispconfig_installation_summary.txt"
}

# Main installation function
main() {
    echo -e "${PURPLE}"
    echo "=========================================="
    echo "  Universal ISPConfig Installation Script"
    echo "=========================================="
    echo -e "${NC}"
    
    log "Starting ISPConfig installation..."
    
    __check_root
    __detect_distro
    __generate_passwords
    __set_hostname
    
    __update_system
    __install_base_packages
    __configure_firewall
    __install_apache
    __install_mysql
    __install_php
    __install_mail
    __install_ftp
    __install_tools
    __install_ispconfig
    __configure_ssl
    __final_configuration
    __create_summary
    
    echo -e "${GREEN}"
    log "=========================================="
    log "ISPConfig installation completed successfully!"
    log "=========================================="
    echo -e "${NC}"
    log ""
    log "Access your ISPConfig admin panel at:"
    log "https://$HOSTNAME:$ADMIN_PORT"
    log "or"
    log "https://$(hostname -I | awk '{print $1}'):$ADMIN_PORT"
    log ""
    log "Login credentials:"
    log "Username: admin"
    log "Password: $ISPCONFIG_DB_PASSWORD"
    log ""
    log "PHP test page: http://$HOSTNAME/phpinfo.php"
    log "Full installation summary: /root/ispconfig_installation_summary.txt"
    log ""
    warn "IMPORTANT: Save your passwords and change them after first login!"
    warn "MySQL root password: $MYSQL_ROOT_PASSWORD"
    echo -e "${NC}"
}

# Run main function
main "$@"
