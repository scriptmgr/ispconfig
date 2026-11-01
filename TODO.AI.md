# TODO.AI.md — ispconfig

Open items only. The installer deliberately configures no firewall; that is the
sysadmin's / ISPConfig's job, not a defect.

## Verification coverage

- Verified end to end on stock cloud images under libvirt, both plain and after
  the maintainer's `min.sh` bootstrap: AlmaLinux 9 and 10, Rocky Linux 9,
  Debian 12 and 13, Ubuntu 22.04 and 24.04. Each run installs with a real Let's
  Encrypt certificate as the panel certificate, creates a client, website and
  mailbox through the ISPConfig remote API, then checks PHP over HTTPS with that
  certificate, an inbound and an authenticated mail round trip, and the same
  after a reboot.
- Not tested: a host that already runs MariaDB with an unknown root password.
  The installer should fail loudly there.
- Not tested: openSUSE, Fedora, CentOS/RHEL 7-8, Ubuntu 18/20, Debian 9-11,
  Rocky 8/10, AlmaLinux 8.
- Not tested: ISPConfig's own Let's Encrypt (acme.sh) issuance, and
  `certbot renew` (needs DNS credentials not present in the test VMs).

## Known issues

- While ISPConfig's own installer runs, amavisd and Dovecot fail to restart a
  few times (ISPConfig sets permissions or certificate paths that the
  installer's later repair steps fix). Final state is healthy but the journal
  keeps those errors, plus one `doveadm` core dump on AlmaLinux.
- `error deleting entry from sasldb: BDB0073` (x6) on Debian/Ubuntu comes from
  ISPConfig's own mail setup.
- Debian/Ubuntu log one `Can't locate Mail/SpamAssassin/CompiledRegexps/...`
  line at SpamAssassin start (rules are not pre-compiled; harmless).
- RHEL-family SELinux still logs a few single-shot denials from ISPConfig's own
  scripts (`vlogger` chown capability, systemd unlinking temporary ssh key files
  under `/usr/local/ispconfig`).
- On the first boot after install under heavy host I/O, Apache and ProFTPd start
  slower than systemd's default start timeout; a second boot is clean.
- On `min.sh` hosts (RHEL-family) `min.sh` leaves `/etc` labelled `usr_t`; the
  installer restores default labels under `/etc`. `min.sh` itself exits non-zero
  on Debian/Ubuntu after finishing (its trailing RHEL-only installer) and its
  SELinux "disable" step does not take effect.
- The installer's own temporary logs under `/tmp` trigger SELinux `load_policy`
  denials on RHEL-family when run from a systemd unit; silenced for the
  installer's `semanage`/`setsebool` calls.

## Cleanup

- Unused `SERVICE_MANAGER` variable in `install.sh` (shellcheck SC2034).
