# TODO.AI.md — ispconfig

Open items only. The installer deliberately configures no firewall; that is the
sysadmin's / ISPConfig's job, not a defect.

## Verification gaps

- The Apache-direct design is verified on AlmaLinux 9 and Debian 12, each on a
  base prepared by the maintainer's `min.sh`. It still needs a run on stock
  Rocky 9, Debian 13 and Ubuntu 22.04/24.04 images.
- Not tested: a host that already runs MariaDB with an unknown root password.
  The installer should fail loudly there.
- Not tested: openSUSE, Fedora, CentOS/RHEL 7-8, Ubuntu 18/20, Debian 9-11.
- Not tested: ISPConfig's own Let's Encrypt (acme.sh) certificates against the
  Apache-direct layout.

## Conventions

- The hostname fallback when no domain can be detected is `.local`
  (`__detect_hostname`). `networking_conventions.md` says private names use
  `.internal`, because `.local` is reserved for mDNS. Changing it alters the
  default FQDN written to the summary, `/etc/hosts` and mail config, so decide
  before changing it.
