# TODO.AI.md — ispconfig

Found by an AlmaLinux 9.8 end-to-end VM test (libvirt, cloud-init, SSH key). The
installer reported every step `[OK]` and exited 0, but the machine was left broken.

## Reporting

- `__step` reports `[OK]` even when the step's work failed — nginx, httpd and
  dovecot were all `failed` after a "successful" run. Two causes:
  1. A function called as `if { "$@"; }` runs with `set -e` suspended, so a
     mid-function failure does not abort it; only the last command's status
     counts. `__configure_apache_backend` ends in `__success ...`, so a failed
     `systemctl restart httpd` still yields 0.
  2. Later steps repeat earlier failures — `systemctl enable --now` is masked by
     an `if systemctl is-active ...` that is false after a failed start, so
     `__final_configuration` never notices httpd/nginx are dead.
  This violates AI.md's "Never leave a step half-applied on failure" and makes
  the `[FAILED]` contract meaningless on dnf-based distros.

## SELinux (distro: almalinux, dnf, firewalld)

- Custom ports are never labelled, so httpd and nginx are both denied
  `name_bind` and fail to start. Needs
  `semanage port -a -t http_port_t -p tcp <port>` for the discovered app port,
  the backend port, the panel port, and `ADMIN_PORT`. The app port is only
  known at runtime (`__install_ispconfig` grep), so labelling must follow it.
- `httpd_can_network_connect` stays off, so nginx cannot proxy to Apache on
  loopback — every panel/web request is a 502. Needs `setsebool -P`.

## ISPConfig panel

- The autoinstaller grants the DB user to the server FQDN, but
  `config.inc.php` gets `db_host = '127.0.0.1'`, which MariaDB resolves to
  `localhost` — no matching grant, so the panel dies with
  `queryOneRecord() on false`. Set `db_host` to the same FQDN the grant uses.
- Open: the panel still returns 500 through Apache/mod_fcgid
  (`mod_fcgid: error reading data from FastCGI server`, child dies
  immediately). The same `index.php` returns a correct 302 to `/login/` when
  run directly as `ispconfig`, so the defect is in the fcgid/suexec layer, not
  PHP. Not reproduced by switching `FCGIWrapper` to `FcgidWrapper`, nor by
  switching MPM from event to prefork. `suexec_log` is empty and no AVC denial
  is recorded.

## Incidental

- `postalias` is denied `read` on `/var/lib/aliases` (`var_lib_t`) — postfix
  log noise, harmless but should be labelled (`semanage fcontext`).
- `vlogger` cannot `mkdir` under `/var/log/ispconfig/httpd`; every vhost emits
  `AH00106` and access logging is dead. Directory is not created/writable.
