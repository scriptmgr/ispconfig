# TODO.AI.md — ispconfig

Open items only. All defects found so far are fixed and were verified on clean
VMs. The installer deliberately configures no firewall; that is the
sysadmin's / ISPConfig's job, not a defect.

## Verification gaps

- Not tested: a host that already runs MariaDB with an unknown root password
  (needs service control the test harness could not use). The installer should
  fail loudly there; confirm on a disposable VM.
- Not tested: openSUSE, Fedora, CentOS/RHEL 7-8, Ubuntu 18/20, Debian 9-11.
  Only AlmaLinux 9, Rocky 9, Debian 12/13 and Ubuntu 22.04/24.04 were run.

## Lint

- `install.sh` line 528 (nginx `ssl_ciphers`, 232 chars) exceeds 180: a single
  directive that cannot be wrapped.
