## Project description

A single, self-contained bash script that installs a full ISPConfig hosting control panel stack on a bare Linux server, automatically, with zero interactive prompts. It targets sysadmins standing up a new hosting box who want ISPConfig's panel plus a production-grade Nginx + Apache + PHP (multi-version) + mail + FTP + DNS stack without hand-running dozens of package installs and config edits. The script detects the distro, generates all credentials at runtime, and drives ISPConfig's own autoinstaller with a prebuilt answer file — Nginx sits in front as the SSL-terminating reverse proxy, with Apache on loopback running PHP.

## Project variables

project_name: ispconfig
project_org: scriptmgr
internal_name: ispconfig
internal_org: scriptmgr
official_site: https://github.com/scriptmgr/ispconfig

## Business logic

- Must work with zero interactive prompts — fully unattended from a single invocation
- Must be distro-agnostic across the package managers it supports: apt, dnf, yum, zypper
- Must generate all passwords/secrets at runtime — never ship or require a static credential
- Must install ISPConfig with Nginx terminating TLS in front of Apache (Apache never exposed directly)
- Must support multiple co-installed PHP versions (5.6 through the current stable)
- Must produce a written summary of generated credentials and next steps for the operator
- Must fail loudly and stop on any step that cannot complete — never continue past a broken step
- Must not require any companion tooling, build step, or runtime beyond bash and the target distro's own package manager — the script is the whole deliverable
- Root privileges are a hard requirement (it manages system packages and services)
- Must be safe to review before running (plain-text bash, no obfuscation, no remote code fetched and executed blindly)
