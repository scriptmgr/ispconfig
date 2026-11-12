# TODO.AI.md — ispconfig

Open items only. The installer deliberately configures no firewall; that is the
sysadmin's / ISPConfig's job, not a defect.

## Verification coverage

- Final pass on stock cloud images under libvirt: AlmaLinux 9 and 10, Rocky Linux 9,
  Debian 12 and 13, Ubuntu 22.04 and 24.04. Each run installs with a real Let's Encrypt
  certificate, creates a client, two sites (PHP 7.4 and 8.5), database, FTP user, mail
  domain, mailboxes, alias and DNS zone through the ISPConfig remote API, then checks
  PHP over HTTP, FTP over explicit TLS, SMTP/IMAP/POP3, spam and virus handling, relay
  refusal and DNS. The same checks pass again after a reboot. The installer prints no
  warnings or errors, and no SELinux denials remain on RHEL-family.
- Not tested: a host that already runs MariaDB with an unknown root password.
  The installer should fail loudly there.
- Not tested: openSUSE, Fedora, CentOS/RHEL 7-8, Ubuntu 18/20, Debian 9-11, AlmaLinux 8.
- Not tested: ISPConfig's own Let's Encrypt (acme.sh) issuance, and `certbot renew`.

## Known issues

- While ISPConfig's own installer runs, amavisd and Dovecot fail to restart a
  few times (ISPConfig sets permissions or certificate paths that the
  installer's later repair steps fix). Final state is healthy but the journal
  keeps those errors, plus one `doveadm` core dump on AlmaLinux.
- `error deleting entry from sasldb: BDB0073` (x6) on Debian/Ubuntu comes from
  ISPConfig's own mail setup.
- Debian/Ubuntu log one `Can't locate Mail/SpamAssassin/CompiledRegexps/...`
  line at SpamAssassin start (rules are not pre-compiled; harmless).
- RHEL-family: the installer loads a small `ispconfig_local` SELinux module so
  ISPConfig's `vlogger` chown and service-run `restorecon` no longer log denials.
- After a reboot the journal at warning level still carries only upstream or
  environment lines: Debian/Ubuntu package SysV-unit notices (`pure-ftpd-mysql`,
  ISPConfig's `bastille-firewall` script), Postfix's `not owned by root:
  /var/spool/postfix/etc/resolv.conf` on Debian 13, MariaDB's own `debian-start`
  upgrade-check messages on Ubuntu 22.04, and (in the test VMs) the test domain's
  missing DKIM DNS record and a hostname that does not resolve to its DHCP address.
- On the first boot after install under heavy host I/O, Apache and Pure-FTPd start
  slower than systemd's default start timeout; a second boot is clean.
- On `min.sh` hosts (RHEL-family) `min.sh` leaves `/etc` labelled `usr_t`; the
  installer restores default labels under `/etc`. `min.sh` itself exits non-zero
  on Debian/Ubuntu after finishing (its trailing RHEL-only installer) and its
  SELinux "disable" step does not take effect.
- The installer's own temporary logs under `/tmp` trigger SELinux `load_policy`
  denials on RHEL-family when run from a systemd unit; silenced for the
  installer's `semanage`/`setsebool` calls.
