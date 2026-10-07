# Context

The previous AlmaLinux 9.8 test used an ad-hoc VM/disk workflow and exposed multiple installer defects, including SELinux port/file labels, Apache/vlogger permissions, PHP-FCGI failures, and service-health validation gaps. The installer must be retested repeatedly from a clean baseline until a fully unattended run completes with all required services healthy and the ISPConfig panel usable. The reusable baseline must be an explicitly named VM/disk containing `ipa`, with a clean snapshot so later test runs restore instead of rebuilding or redownloading.

# Recommended approach

1. **Rebuild and name the reusable baseline**
   - Redownload the AlmaLinux 9 ISO into the project-controlled test workspace and verify it is usable before booting.
   - Replace the existing ad-hoc test artifacts with consistently named resources containing `ipa`, e.g. `ispconfig-ipa-base` and `ispconfig-ipa-base.qcow2`; remove/undefine only stale test resources, never production resources.
   - Install the minimal AlmaLinux 9 base OS, configure the project test network and SSH key, complete initial OS setup, shut down cleanly, and create a qcow2 internal snapshot named `ipa-clean-base`.
   - Keep the base VM/disk and snapshot as the canonical restore point. Create disposable clean test VMs/disks from that snapshot or a backing copy for each installer attempt.

2. **Make installer failures fail loudly and validate real health**
   - Continue using the existing `__step`/`__failed` workflow, but ensure wrapped functions cannot hide failures behind a final success message.
   - In final configuration, explicitly require `systemctl is-active` for every required service and verify configuration tests (`nginx -t`, `httpd -t`, relevant mail configuration checks) before reporting success.
   - Preserve distro/package-manager branching and the AI.md requirement that no failed phase is allowed to continue.

3. **Finish SELinux/runtime corrections in `install.sh`**
   - Reuse `__configure_selinux` and its existing `semanage`/`restorecon` patterns.
   - Label all runtime Apache ports, remove conflicting SELinux port types before assigning `http_port_t`, and enable the required network booleans.
   - Apply executable context and traversable permissions to the actual ISPConfig vlogger path (`/usr/local/ispconfig/server/scripts/vlogger`), not the obsolete class path.
   - Create `/var/log/ispconfig/httpd` with ownership/mode and a context that permits the Apache vlogger to create per-host logs; apply labels after all directory creation and avoid later recursive relabeling undoing the executable/runtime permissions.
   - Keep the postfix aliases label and PHP CGI OPcache workaround, then validate each affected operation under the actual Apache/PHP service account.

4. **Resolve the remaining panel/FastCGI defect rather than masking it**
   - Reproduce the current HTTP 500 on a disposable restored clean VM, inspect Apache/fcgid/suexec logs and AVCs, and trace the failing `index.php` execution path.
   - Fix the root cause in the installer configuration (including file contexts, directory traversal, CGI starter permissions, runtime lock paths, and service ordering as applicable), not by disabling the panel check.
   - Keep the final panel check strict: HTTPS request to the configured panel port must return the expected redirect/login response, not merely a running nginx process.

5. **Repeat clean restore/test/fix cycles**
   - For every iteration, restore `ipa-clean-base`, create a disposable VM with a name containing `ipa`, copy the current script, run it unattended, and collect step output, service state, configuration-test output, panel HTTP status, and relevant journal/AVC logs.
   - If a run fails, update the script, discard the disposable VM, restore the same clean snapshot, and retest from scratch. Do not use a partially installed VM as a baseline.
   - Continue until the installer exits successfully and all required services are active, Apache/Nginx configuration tests pass, mail/FTP services are healthy, the panel returns the expected login redirect, and vlogger creates a test access log.

6. **Repository verification**
   - Keep all edits under the project directory; do not commit.
   - Bump both the header and `VERSION` value on every `install.sh` edit.
   - Run `bash -n install.sh`, `git diff --check`, the required script-lint workflow, and the complete clean-VM end-to-end test described in AI.md before reporting completion.
   - Update `TODO.AI.md` only to reflect verified fixes and remaining work; do not mark unresolved issues complete.

# Critical files

- `install.sh` — installer logic, SELinux policy, service finalization, and panel validation.
- `TODO.AI.md` — verified findings and outstanding AlmaLinux test defects.
- `AI.md` / `IDEA.md` — authoritative implementation and validation requirements.

# Verification

- Confirm the canonical VM and qcow2 names contain `ipa`, the internal snapshot is present, and the ISO is available locally.
- Restore a disposable VM from `ipa-clean-base` and run the installer unattended.
- Verify exit status, all required `systemctl is-active` checks, `nginx -t`, `httpd -t`, mail-stack checks, panel HTTPS status, and vlogger log creation.
- Repeat from the clean snapshot after each fix until no failure remains; then run syntax, diff, and script-lint checks.
