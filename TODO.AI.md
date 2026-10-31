# TODO.AI.md — ispconfig

Open items only. The installer deliberately configures no firewall; that is the
sysadmin's / ISPConfig's job, not a defect.

## Verification gaps

- Verified end to end on stock cloud images (libvirt): AlmaLinux 9 and 10,
  Debian 12 and 13. Still needs a run on stock Rocky 9 and Ubuntu 22.04/24.04.
- Not tested: a host that already runs MariaDB with an unknown root password.
  The installer should fail loudly there.
- Not tested: openSUSE, Fedora, CentOS/RHEL 7-8, Ubuntu 18/20, Debian 9-11.
- Not tested: ISPConfig's own Let's Encrypt (acme.sh) certificates against the
  Apache-direct layout.

## Known transients

- While ISPConfig's own installer runs, amavisd, Dovecot and (on Debian) amavis
  fail to restart a few times: ISPConfig sets permissions or certificate paths
  that the installer's later repair steps fix. Final state is healthy
  (`systemctl --failed` empty) but the journal keeps those errors, plus one
  `doveadm` core dump on AlmaLinux from the Dovecot restart failure.
- `error deleting entry from sasldb: BDB0073` (x6) on Debian comes from
  ISPConfig's own mail setup.

## Cleanup

- Unused `SERVICE_MANAGER` variable in `install.sh` (shellcheck SC2034).
