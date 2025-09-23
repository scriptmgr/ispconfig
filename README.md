# Universal ISPConfig Installation Script

A comprehensive, distro-agnostic installation script for ISPConfig hosting control panel that supports multiple Linux distributions and PHP versions out of the box.

## 🌟 Features

- **🌍 Universal Compatibility** - Works across all ISPConfig-supported Linux distributions
- **🐘 Multiple PHP Versions** - Installs PHP 5.6 through 8.3 with full extension support
- **🔧 Automated Configuration** - Complete LAMP/LEMP stack setup with optimal settings
- **🛡️ Security First** - Automatic firewall configuration and SSL certificate generation
- **📊 Smart Detection** - Automatically detects distribution and adapts installation accordingly
- **⚡ Production Ready** - Configured for hosting environments with proper service management

## 📋 Supported Distributions

| Distribution | Versions | Package Manager | Status |
|--------------|----------|-----------------|--------|
| **Ubuntu** | 18.04, 20.04, 22.04, 24.04 | apt | ✅ Fully Supported |
| **Debian** | 9, 10, 11, 12 | apt | ✅ Fully Supported |
| **CentOS** | 7, 8, 9 | yum/dnf | ✅ Fully Supported |
| **RHEL** | 7, 8, 9 | yum/dnf | ✅ Fully Supported |
| **AlmaLinux** | 8, 9, 10 | dnf | ✅ Fully Supported |
| **Rocky Linux** | 8, 9, 10 | dnf | ✅ Fully Supported |
| **Fedora** | 36-49 | dnf | ✅ Fully Supported |
| **openSUSE Leap** | 15.x | zypper | ✅ Fully Supported |
| **SLES** | 15.x | zypper | ✅ Fully Supported |

## 🚀 Quick Installation

### Option 1: One-liner (Quick Start)
```bash
curl -sSL https://raw.githubusercontent.com/scriptmgr/ispconfig/main/install.sh | bash
```

### Option 2: Download and Review (Recommended)
```bash
wget https://raw.githubusercontent.com/scriptmgr/ispconfig/main/install.sh
chmod +x install.sh
./install.sh
```

### Option 3: Git Clone
```bash
git clone https://github.com/scriptmgr/ispconfig.git
cd ispconfig
chmod +x install.sh
./install.sh
```

## ⚙️ What Gets Installed

### Core Components
- **Web Server**: Apache with SSL and mod_rewrite
- **Database**: MariaDB with secure configuration
- **Mail Server**: Postfix + Dovecot with MySQL integration
- **FTP Server**: Pure-FTPd with MySQL authentication
- **DNS Server**: BIND9/named
- **Control Panel**: ISPConfig 3 (latest stable)

### PHP Versions
- PHP 5.6, 7.0, 7.1, 7.2, 7.3, 7.4, 8.0, 8.1, 8.2, 8.3
- All versions include common extensions: mysql, gd, mbstring, xml, curl, zip, soap, intl, bcmath, opcache
- Individual PHP-FPM pools for each version
- ISPConfig integration with version selection per website

### Security & Monitoring
- Automatic firewall configuration (UFW/firewalld)
- SSL certificates for ISPConfig admin panel
- ClamAV antivirus
- SpamAssassin anti-spam
- Fail2ban (planned for future release)

### Additional Tools
- Awstats and Webalizer for statistics
- Rsync for backups
- Quota management
- Cron job management

## 🔧 Configuration

### Default Settings
- **ISPConfig Admin Port**: 64245 (customizable in script)
- **Web Root**: `/var/www/html` (or `/srv/www/htdocs` on openSUSE)
- **PHP Default Version**: 8.1
- **Database**: MariaDB with auto-generated secure passwords
- **SSL**: Self-signed certificates (recommend Let's Encrypt for production)

### Custom Configuration
You can modify the script variables at the top of the file:
```bash
ADMIN_PORT=64245                    # ISPConfig admin port
PHP_VERSIONS=("5.6" "7.0" ... "8.3")  # PHP versions to install
```

## 📖 Post-Installation

### Access ISPConfig
1. Open your browser and navigate to: `https://your-server-ip:64245`
2. Login with:
   - **Username**: `admin`
   - **Password**: Check `/root/ispconfig_installation_summary.txt`

### Test PHP Versions
Visit `http://your-server-ip/phpinfo.php` to see all installed PHP versions.

### First Steps
1. **Change default passwords** in ISPConfig admin panel
2. **Configure your first website** and select desired PHP version
3. **Set up email accounts** and test mail functionality
4. **Configure DNS** if using ISPConfig's DNS management
5. **Set up SSL certificates** (Let's Encrypt recommended for production)

## 📁 Important Files & Locations

### Configuration Files
```
/usr/local/ispconfig/                    # ISPConfig installation
/root/ispconfig_installation_summary.txt # Installation summary & passwords
/root/.my.cnf                           # MySQL root credentials
```

### Service Management
```bash
# Restart services
systemctl restart apache2      # Ubuntu/Debian
systemctl restart httpd        # RHEL-based
systemctl restart mariadb
systemctl restart postfix
systemctl restart dovecot
systemctl restart pure-ftpd

# PHP-FPM services
systemctl restart php8.1-fpm   # Ubuntu/Debian
systemctl restart php81-php-fpm # RHEL-based
```

### Log Files
```
/var/log/ispconfig/             # ISPConfig logs
/var/log/apache2/               # Web server logs (Ubuntu/Debian)
/var/log/httpd/                 # Web server logs (RHEL-based)
/var/log/mail.log               # Mail server logs
```

## 🐛 Troubleshooting

### Common Issues

**1. Installation fails on unsupported distribution**
```bash
# Check if your distribution is supported
cat /etc/os-release
```

**2. Cannot access ISPConfig admin panel**
```bash
# Check if firewall allows the admin port
firewall-cmd --list-ports                    # RHEL-based
ufw status                                    # Ubuntu/Debian

# Check if ISPConfig is running
systemctl status ispconfig_server
```

**3. PHP version not available in ISPConfig**
```bash
# Verify PHP versions are installed
ls /usr/local/bin/php*

# Check PHP-FPM services
systemctl status php*-fpm
```

**4. Email not working**
```bash
# Check mail services
systemctl status postfix dovecot

# Check mail logs
tail -f /var/log/mail.log
```

### Getting Help

1. **Check the installation summary**: `/root/ispconfig_installation_summary.txt`
2. **Review ISPConfig logs**: `/var/log/ispconfig/`
3. **Open an issue**: [GitHub Issues](https://github.com/scriptmgr/ispconfig/issues)
4. **ISPConfig Documentation**: [https://www.ispconfig.org/documentation/](https://www.ispconfig.org/documentation/)

## 🤝 Contributing

We welcome contributions! Here's how you can help:

### Reporting Issues
- Use the [GitHub Issues](https://github.com/scriptmgr/ispconfig/issues) page
- Include your distribution name and version
- Provide relevant log excerpts
- Describe the expected vs actual behavior

### Contributing Code
1. Fork the repository
2. Create a feature branch: `git checkout -b feature/new-feature`
3. Make your changes and test on multiple distributions
4. Commit with clear messages: `git commit -m "Add support for XYZ"`
5. Push to your fork: `git push origin feature/new-feature`
6. Create a Pull Request

### Testing
Help us test on different distributions:
- Test the script on various Linux distributions
- Report compatibility issues
- Suggest improvements for specific distributions

## 📝 Changelog

### v1.0.0
- Initial release with universal distribution support
- Multiple PHP versions (5.6-8.3)
- Automated ISPConfig installation
- Security hardening and firewall configuration

## ⚠️ Security Considerations

### For Production Use
1. **Change default passwords** immediately after installation
2. **Configure proper SSL certificates** (Let's Encrypt recommended)
3. **Remove or secure test files** like `phpinfo.php`
4. **Regular security updates**: Keep all packages updated
5. **Backup strategy**: Implement regular backups of databases and configurations
6. **Firewall review**: Adjust firewall rules for your specific needs

### Network Security
- The script opens standard hosting ports (80, 443, 21, 25, 110, 143, etc.)
- ISPConfig admin panel uses custom port (64245) for security
- Consider changing SSH port and implementing key-based authentication
- Use fail2ban for additional intrusion prevention

## 📊 System Requirements

### Minimum Requirements
- **RAM**: 2GB (4GB+ recommended for production)
- **Storage**: 20GB available space (50GB+ recommended)
- **Network**: Static IP address recommended
- **Root Access**: Required for installation

### Recommended Specifications
- **RAM**: 8GB or more for busy hosting environments
- **Storage**: SSD storage for better performance
- **CPU**: 2+ cores for multiple websites
- **Network**: Dedicated server or VPS with good bandwidth

## 🔗 Related Projects

- **ISPConfig**: [https://www.ispconfig.org/](https://www.ispconfig.org/)
- **Let's Encrypt**: [https://letsencrypt.org/](https://letsencrypt.org/)
- **Remi Repository**: [https://rpms.remirepo.net/](https://rpms.remirepo.net/)
- **Ondřej Surý PHP PPA**: [https://launchpad.net/~ondrej/+archive/ubuntu/php](https://launchpad.net/~ondrej/+archive/ubuntu/php)

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **ISPConfig Team** for creating an excellent hosting control panel
- **Remi Collet** for maintaining comprehensive PHP packages for RHEL-based systems
- **Ondřej Surý** for maintaining PHP packages for Debian/Ubuntu systems
- **Community contributors** who test and improve this script

---

**⭐ If this script helped you, please consider starring the repository!**

For professional hosting management and ISPConfig consulting, visit [ISPConfig.org](https://www.ispconfig.org/).
