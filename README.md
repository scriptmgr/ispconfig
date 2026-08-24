# Universal ISPConfig Installation Script

A comprehensive, distro-agnostic installation script for ISPConfig hosting control panel. Installs a full LEMP/LAMP stack with Nginx as the SSL-terminating reverse proxy in front of Apache, multiple co-installable PHP versions, and a complete mail stack — fully automated with zero interactive prompts.

---

## 📦 Install

```bash
# Download and review first (recommended)
wget https://raw.githubusercontent.com/scriptmgr/ispconfig/main/install.sh
chmod +x install.sh
bash install.sh
```

The script must be run as root. It detects your distribution automatically and requires no configuration.

Output is one line per install step (with a spinner while it runs) — package-manager noise is captured, not streamed. A step that fails prints `[FAILED]` plus the last 40 lines of its captured log and stops the script.

---

## ✨ Features

- **🌍 Universal compatibility** — works across all major Linux distributions
- **🐘 Multiple PHP versions** — installs PHP 5.6 through 8.5 with full extension support
- **🔀 Nginx + Apache architecture** — Nginx handles SSL termination and static assets; Apache runs PHP on a loopback backend port
- **🔧 Fully automated** — no interactive prompts; generates all passwords at runtime
- **🛡️ Security first** — firewall rules, TLS 1.2/1.3 only, HSTS, DH params, OCSP stapling
- **📧 Production mail stack** — Postfix + Dovecot + OpenDKIM with submission and SMTPS ports
- **⚡ Production ready** — Event MPM, RemoteIP passthrough, PHP-FPM pools, logrotate

---

## 📋 Supported Distributions

| Distribution | Versions | Package Manager | Status |
|---|---|---|---|
| **Ubuntu** | 18.04–24.04 | apt | ✅ 24.04 tested |
| **Ubuntu** | 25.x, 26.04 | apt | ⚠️ experimental — PHP 8.5 only; Dovecot 2.4 config pending |
| **Debian** | 9, 10, 11, 12, 13 | apt | ✅ 12 tested |
| **AlmaLinux** | 8, 9, 10 | dnf | ✅ 9 tested |
| **Rocky Linux** | 8, 9, 10 | dnf | supported, untested |
| **CentOS / RHEL** | 7, 8, 9 | yum / dnf | ⚠️ use at own risk — requires active subscription |
| **Fedora** | 36–49 | dnf | supported, untested |
| **openSUSE Leap / SLES** | 15.x | zypper | supported, untested |

> **RHEL note:** This script is tested against AlmaLinux (a free RHEL rebuild). Vanilla RHEL requires an active subscription for package repos and uses different repo names for CodeReady Builder — the script may need manual repo adjustments. Rocky Linux 9 is expected to work identically to AlmaLinux 9 but has not been tested.

> **Ubuntu 25.x / 26.04 note:** These releases are detected and partially supported. The Ondrej PHP PPA does not yet carry packages for these codenames, so only the PHP version shipped natively by Ubuntu (8.5 on 26.04) is installed. Ubuntu 26.04 ships Dovecot 2.4, which has a breaking configuration format change (new `dovecot_config_version` header required, renamed settings, `passdb`/`userdb` block syntax change); full Dovecot 2.4 support is pending.

---

## 🏗️ Architecture

```
Internet
   │
   ▼
Nginx :80        → redirect to HTTPS
Nginx :443       → TLS termination → Apache 127.0.0.1:81  (websites)
Nginx :64245     → TLS termination → Apache 127.0.0.1:7080 (ISPConfig panel)
```

Apache listens only on loopback. All TLS, HSTS, and caching are handled by Nginx. PHP runs via FPM pools. ISPConfig manages Apache vhost templates and DNS; Nginx picks up Let's Encrypt certificates automatically via a deploy hook.

---

## ⚙️ What Gets Installed

| Component | Software |
|---|---|
| Frontend proxy | Nginx (Event, SSL, gzip, open-file-cache) |
| Web backend | Apache (Event MPM, mod-fcgid, RemoteIP) |
| Database | MariaDB (secured, root password in `/root/.my.cnf`) |
| PHP | 5.6, 7.0, 7.1, 7.2, 7.3, 7.4, 8.0, 8.1, 8.2, 8.3, 8.4, 8.5 with FPM |
| Mail | Postfix + Dovecot + OpenDKIM (ports 25, 465, 587, 143, 993, 110, 995) |
| FTP | ProFTPd with MySQL authentication |
| DNS | BIND9 / named |
| Control panel | ISPConfig 3 (latest stable) |
| Anti-spam | SpamAssassin + Amavisd-new |
| Antivirus | ClamAV |
| Stats | Awstats, Webalizer |
| SSL | Self-signed certs at install; Let's Encrypt via certbot + auto-sync hook |

PHP extensions installed per version: `mysql`, `pgsql`, `sqlite3`, `gd`, `imagick`, `mbstring`, `xml`, `curl`, `zip`, `soap`, `intl`, `bcmath`, `opcache`, `readline`, `bz2`, `xsl`, `tidy`, `ldap`, `imap`, `gettext`, `exif`, `sockets`, `redis`, `memcached`.

---

## 📖 Post-Installation

### Access the panel

```
https://<server-ip>:64245
Username: admin
Password: see /root/ispconfig_installation_summary.txt
```

### Summary file

All generated credentials, architecture details, port mapping, and next steps are written to:

```
/root/ispconfig_installation_summary.txt
```

### Let's Encrypt workflow

```bash
# Issue a cert (ACME webroot is pre-configured at /var/www/letsencrypt)
certbot certonly --webroot -w /var/www/letsencrypt -d example.com -d www.example.com

# Sync cert to Nginx vhosts (runs automatically on renewal via deploy hook)
/usr/local/bin/ispconfig-nginx-sync
```

### Test PHP versions

Visit `http://<server-ip>/phpinfo.php` — lists all installed PHP versions and confirms `X-Forwarded-Proto` passthrough. **Remove before going live.**

---

## 📁 Key Paths

| Path | Purpose |
|---|---|
| `/usr/local/ispconfig/` | ISPConfig root |
| `/root/ispconfig_installation_summary.txt` | Credentials and next steps |
| `/root/.my.cnf` | MariaDB root credentials |
| `/etc/nginx/nginx.conf` | Nginx main config |
| `/etc/nginx/vhosts.d/` | Nginx virtual host drop-ins |
| `/etc/postfix/main.cf` | Postfix config |
| `/etc/dovecot/conf.d/` | Dovecot config |
| `/etc/opendkim.conf` | OpenDKIM config |
| `/usr/local/bin/ispconfig-nginx-sync` | Cert sync helper |

### Add a custom Nginx vhost

```bash
# Drop a .conf file and reload — no ISPConfig involvement needed
cat > /etc/nginx/vhosts.d/myapp.conf << 'EOF'
server {
    listen 443 ssl;
    server_name myapp.example.com;
    ssl_certificate     /etc/letsencrypt/live/myapp.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/myapp.example.com/privkey.pem;
    location / { proxy_pass http://127.0.0.1:3000; }
}
EOF
nginx -t && systemctl reload nginx
```

---

## 🛡️ DKIM / SPF / DMARC

OpenDKIM is installed and wired into Postfix. Keys are generated per-domain through the ISPConfig UI (DNS → Zones → DKIM).

After generating a key, add these DNS records:

```
# DKIM
mail._domainkey.example.com  TXT  "v=DKIM1; k=rsa; p=<key from ISPConfig>"

# SPF
example.com  TXT  "v=spf1 a mx ip4:<server-ip> ~all"

# DMARC
_dmarc.example.com  TXT  "v=DMARC1; p=quarantine; rua=mailto:admin@example.com"
```

Also set a **PTR record** (reverse DNS) for your server IP → `<hostname>` with your VPS provider.

---

## 🔧 Service Management

```bash
# Nginx
systemctl reload nginx          # reload config without dropping connections
systemctl restart nginx

# Apache (Debian/Ubuntu)
systemctl restart apache2

# Apache (RHEL-family)
systemctl restart httpd

# PHP-FPM (Debian/Ubuntu — replace 8.4 with any installed version)
systemctl restart php8.4-fpm

# PHP-FPM (RHEL-family)
systemctl restart php84-php-fpm

# Mail
systemctl restart postfix dovecot opendkim

# FTP
systemctl restart proftpd

# MariaDB
systemctl restart mariadb
```

---

## 🐛 Troubleshooting

**Cannot reach the ISPConfig panel**
```bash
ufw status                        # Debian/Ubuntu
firewall-cmd --list-ports         # RHEL-family
systemctl status nginx apache2    # check both are running
```

**PHP version missing in ISPConfig**
```bash
ls /usr/bin/php*                    # Debian/Ubuntu installed versions
ls /opt/remi/php*/root/usr/bin/php  # RHEL-family
systemctl status 'php*-fpm'
```

**Mail not delivering**
```bash
systemctl status postfix dovecot opendkim
tail -f /var/log/mail.log
postconf smtpd_milters              # verify OpenDKIM is wired in
```

**Nginx config test**
```bash
nginx -t
```

**A step reports `[FAILED]`**
The captured log tail printed with the failure shows the actual package-manager or config error — scroll up in the terminal to see it; nothing else is hidden.

---

## 📊 System Requirements

| | Minimum | Recommended |
|---|---|---|
| RAM | 2 GB | 4 GB+ |
| Disk | 20 GB | 50 GB+ SSD |
| CPU | 1 core | 2+ cores |
| Network | Any | Static IP |

Root access is required.

---

## ⚠️ Security Notes

- All passwords are randomly generated at install time and saved to `/root/ispconfig_installation_summary.txt` — secure this file
- SSL certificates are self-signed at install — replace with Let's Encrypt before serving traffic
- Remove `/var/www/html/phpinfo.php` before going live
- Review opened firewall ports and close any not needed for your use case
- Set a PTR record (reverse DNS) for your IP — required for reliable mail delivery

---

## 🤝 Contributing

Issues and pull requests are welcome on [GitHub](https://github.com/scriptmgr/ispconfig). When reporting a bug please include:

- Distribution name and version (`cat /etc/os-release`)
- Relevant lines from the install log
- Expected vs actual behaviour

---

## 🙏 Acknowledgments

- [ISPConfig](https://www.ispconfig.org/) — the hosting control panel this script deploys
- [Ondřej Surý](https://launchpad.net/~ondrej/+archive/ubuntu/php) — PHP packages for Debian/Ubuntu
- [Remi Collet](https://rpms.remirepo.net/) — PHP packages for RHEL-family systems

---

## 📜 License

MIT — see [LICENSE.md](LICENSE.md).
