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

The script must be run as root. It detects your distribution automatically and requires no configuration. Credentials are generated automatically unless you provide overrides through environment variables.

The installer is for fresh servers: if ISPConfig is already installed (`/usr/local/ispconfig`), it stops immediately instead of regenerating credentials that would no longer match the running system.

Output is one line per install step (with a spinner while it runs) — package-manager noise is captured, not streamed. A step that fails prints `[FAILED]` plus the last 40 lines of its captured log and stops the script.

**If you're connecting over SSH, run it inside `tmux`/`screen`.** The first step is a full system upgrade, which can restart `sshd`/`systemd`/`dbus` (directly or via an auto-restart hook like `needrestart`) and kill the SSH session running the script — a terminal multiplexer survives that. The script warns if it detects SSH without one, but running inside `tmux new -s ispconfig` or `screen -S ispconfig` up front avoids the interruption entirely.

### Environment overrides

Set any of these variables before running the installer to choose credentials. If a password variable is unset or empty, the installer generates a random password. The admin username defaults to `admin`.

| Variable | Default | Purpose |
|---|---|---|
| `ISPCONFIG_MYSQL_ROOT_PASSWORD` | Generated | MariaDB root password |
| `ISPCONFIG_ADMIN_PASSWORD` | Generated | ISPConfig panel password |
| `ISPCONFIG_ADMIN_USER` | `admin` | ISPConfig panel username |
| `ISPCONFIG_DB_PASSWORD` | Generated | Password for the ISPConfig database user |
| `ISPCONFIG_PHPINFO` | Disabled | Set to `1` to create the public `phpinfo.php` diagnostic page; see [Test PHP versions](#test-php-versions) |

For example, run with explicit credentials from a root shell:

```bash
ISPCONFIG_ADMIN_USER=paneladmin \
ISPCONFIG_ADMIN_PASSWORD='choose-a-strong-password' \
ISPCONFIG_MYSQL_ROOT_PASSWORD='choose-another-strong-password' \
ISPCONFIG_DB_PASSWORD='choose-a-third-strong-password' \
bash install.sh
```

Passwords may not contain quotes, backslashes, backticks, dollar signs or whitespace, and `ISPCONFIG_ADMIN_USER` may contain only letters, digits, `.`, `_` and `-`; the installer rejects anything else before it changes the system. The installer writes the resulting credentials to `/root/ispconfig_installation_summary.txt` with mode `0600`.

---

## ✨ Features

- **🌍 Universal compatibility** — works across all major Linux distributions
- **🐘 Multiple PHP versions** — installs PHP 7.4 through 8.5, whichever of those the distro's repositories actually offer — see [PHP version coverage](#-php-version-coverage)
- **🔀 Nginx + Apache architecture** — Nginx handles SSL termination and static assets; Apache runs PHP on a loopback backend port
- **🔧 Fully automated** — no interactive prompts; generates passwords by default and supports environment overrides
- **🛡️ Security first** — TLS 1.2/1.3 only, HSTS, DH params, Apache bound to loopback, credentials written mode `0600`. **No firewall is configured** — see [Security Notes](#-security-notes)
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
| PHP | Whatever the distro repos provide, up to 8.5, with FPM — see [PHP version coverage](#-php-version-coverage) |
| Mail | Postfix + Dovecot + OpenDKIM (ports 25, 465, 587, 143, 993, 110, 995) |
| FTP | ProFTPd with MySQL authentication |
| DNS | BIND9 / named, enabled and started at install |
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

# Sync cert to Nginx vhosts and reload Nginx (runs automatically on renewal)
/usr/local/bin/ispconfig-nginx-sync
```

The sync helper processes certificate directories containing both `fullchain.pem` and `privkey.pem`, then tests and reloads Nginx even when the generated vhost configuration text has not changed. OCSP stapling is enabled for a vhost only when its certificate provides an OCSP responder URI and a local CA bundle is available.

### Test PHP versions

`phpinfo.php` is **not created by default**, because `phpinfo()` in a public document root discloses the PHP build, loaded modules, environment and every `*_PASSWD` superglobal.

To generate it for testing, set `ISPCONFIG_PHPINFO=1` before running the installer:

```bash
sudo env ISPCONFIG_PHPINFO=1 bash install.sh
```

Visit `https://<server-ip>/phpinfo.php` (self-signed certificate) to list all installed PHP versions and confirm `X-Forwarded-Proto` passthrough. The page is served by the catch-all no-site vhost; the 404 rule lets only `phpinfo.php` through. **Remove it before going live** (`rm -f /var/www/ispconfig-nosite/phpinfo.php`).

---

## 🐘 PHP version coverage

The supported range is **PHP 7.4 → 8.5**. Each version is installed **only if the distro's repositories actually provide it**. Anything unavailable is skipped with a `WARN` line naming the version — the step still reports `[OK]`, so check the install log for `[WARN] PHP ... not available` to see what you actually got.

| Family | Usual range | Caveat |
|---|---|---|
| Debian / Ubuntu | 7.4 – 8.5 | Ondrej PPA — some series lag the newest releases |
| RHEL / AlmaLinux / Rocky / Fedora | 7.4 – 8.5 (Remi) | — |
| openSUSE / SLES | repo-provided only | varies by distribution |

PHP 5.6 and 7.0–7.3 are **not supported** and are never requested. The installer targets 7.4 as the oldest supported series; anything older must be sourced from an external repository you supply yourself.

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

### Ports to open

The installer configures **no firewall** — this is what you need to allow inbound if you set one up:

| Port | Service | Exposure |
|---|---|---|
| 80 | Nginx HTTP | Public |
| 443 | Nginx HTTPS | Public |
| 64245 | ISPConfig panel | Public (restrict to your IP if possible) |
| 21 | ProFTPd | Public if FTP is used |
| 22 | SSH | Public — **keep this open or you will lock yourself out** |
| 25, 465, 587 | Postfix SMTP / SMTPS / submission | Public if mail is used |
| 110, 143, 993, 995 | Dovecot POP3 / IMAP / IMAPS / POP3S | Public if mail is used |
| 81, 7080, 7081 | Apache backend | Loopback only — never open |

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
systemctl status nginx apache2    # check both are running
ss -lntp | grep -E ':(443|64245)\b'   # confirm they are listening
# If you have enabled a firewall yourself, check what it allows:
ufw status                        # Debian/Ubuntu
firewall-cmd --list-ports         # RHEL-family
```
> The installer does **not** enable or configure a firewall, so these checks only apply if you turned one on.

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

- All passwords are randomly generated at install time and saved to `/root/ispconfig_installation_summary.txt` (mode `0600`) — the installer verifies them against the live system before exiting
- SSL certificates are self-signed at install — replace with Let's Encrypt before serving traffic. OCSP stapling is enabled only for certificates with an OCSP responder URI and an available local CA bundle.
- **The installer configures no firewall.** firewalld/ufw/nftables are left exactly as the base image shipped them — on AlmaLinux that means `iptables` policies `ACCEPT` with no rules. Every port the panel and mail stack bind is world-reachable. Enable and configure a firewall yourself before serving traffic; the ports to open are in [Key Paths](#-key-paths)
- Requests for a hostname with no configured site get a `404` "No site at this address" page (static HTML/CSS, no JavaScript) from a catch-all Apache vhost, `00-ispconfig-nosite.conf`, instead of the distro test page
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
