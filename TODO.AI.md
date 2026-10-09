# TODO.AI.md — ispconfig

Open items only. Every defect from the first AlmaLinux 9.8 VM run (silent
`[OK]` on failed steps, SELinux port/label/boolean gaps, panel `db_host`,
mod_fcgid 500, `postalias` label, vlogger log directory) is fixed and was
verified on a clean VM. The installer deliberately configures no firewall;
that is the sysadmin's / ISPConfig's job, not a defect.

## Verification

- Re-run the full clean-VM install after the catch-all page change and confirm
  `https://<ip>/` answers `404` with the "No site at this address" page and a
  hosted site still resolves by Host header.

## Lint

- Pre-existing script-lint notes: over-long lines, two UUOC pipelines, and
  shellcheck SC2154 / SC2034 / SC2086 findings.
