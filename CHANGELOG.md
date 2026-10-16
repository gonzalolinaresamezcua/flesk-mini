# Changelog

All notable changes to Flesk Mini are documented here.

## 1.0.1-mini (2026-10-16)

- **Default nginx hardening**: blocks web download of sensitive files (`.dat`, `.sql`, `.zip`/`.tar`/`.gz`/`.tgz`, `.bak`/`.old`/`.backup`, `.log`, `.env`, `.ini`, `.sh`) and hidden files (`.git`, `.htaccess`, `.env`…); `autoindex off`. ACME (`/.well-known/acme-challenge/`) remains allowed. `.json` is not blocked.

## [1.0.0-mini] — 2026-10-14

First public release of Flesk Mini, the free 1-domain edition of the Flesk hosting panel.

### Added
- One-command installer (`install.sh`) for clean Ubuntu 24.04 LTS.
- Bilingual (ES/EN) web panel: dashboard, domain, files, DNS (BIND + DKIM), mail (Postfix/Dovecot + Roundcube), SSL (Let's Encrypt), database (MariaDB + Adminer 6.1.1), SFTP.
- `flesk` CLI (`domain`, `dns`, `ssl`, `mail`, `db`, `sftp`).
- Edition limits enforced by the engine (`lib/limits.sh`) and the panel.
- CSRF protection, login lockout, captcha and audit log.
- Upgrade info for the paid editions at https://serverflesk.es.
