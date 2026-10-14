<p align="center"><img src="docs/logo.svg" width="96" alt="Flesk logo"></p>

<h1 align="center">Flesk Mini</h1>
<p align="center"><b>Free trial edition of the Flesk hosting control panel — 1 domain</b><br>
<a href="https://serverflesk.es">serverflesk.es</a> · <a href="README.es.md">Leer en español</a></p>

---

Flesk Mini is a lightweight, self-hosted hosting panel for **one Ubuntu 24.04 server and one domain**.
It lets you try Flesk for real: website, files, DNS, mail, SSL, database and SFTP/FTP, all from a clean bilingual (ES/EN) web panel.

> **Need more than one domain?** At [serverflesk.es](https://serverflesk.es):
> - **Flesk Basic 1.0** — up to **3 domains**, annual licence **€5/year** (VAT incl.) — [buy](https://serverflesk.es/comprar?plan=basico).
> - **Flesk AI 2.0** — **unlimited domains** with **working artificial intelligence** that manages the server for you, annual licence **€12/year** (VAT incl.) — [buy](https://serverflesk.es/comprar?plan=ia).

## Features

| Menu | What it does |
|------|--------------|
| Dashboard | Overview of your domain, mailbox, SSL and database |
| Domain | Create your domain (nginx vhost + PHP-FPM pool isolated per domain) |
| Files | Web file manager (upload, edit, zip, permissions) |
| DNS | Authoritative BIND zone for the domain (A, AAAA, CNAME, MX, TXT…), DKIM |
| Mail | 1 mailbox (Postfix + Dovecot), aliases/forwards, autoresponder, Roundcube webmail |
| SSL | Let's Encrypt certificate for the domain, automatic renewal |
| Database | 1 MariaDB database + Adminer with one-time login |
| FTP | 1 chrooted SFTP user; the panel shows a working connection host (`ftp.<domain>` → `<domain>` → server IP fallback) |

Also: Spanish/English UI with language switcher (Spanish by default), CSRF protection, login lockout, captcha, audit log in the database, `flesk` CLI.

## Trial limits

| Resource | Flesk Mini (free) | Flesk Basic (€5/year) | Flesk AI (€12/year) |
|----------|-----------:|-----------:|-----------:|
| Domains | 1 | 3 | Unlimited |
| Mailboxes | 1 | ✔ | ✔ |
| SSL certificates | 1 | ✔ | ✔ |
| Databases | 1 | ✔ | ✔ |
| SFTP/FTP users | 1 | ✔ | ✔ |
| Backups, statistics, app installer, GitHub deploy | — | see site | ✔ |
| Artificial intelligence | — | — | ✔ |

Limits are enforced by the engine itself (`lib/limits.sh`, used by `domain add`, `mail add`, `db add`, `sftp add`, `ssl issue`) and checked again by the web panel (`web/public/includes/limits.php`). Exceeding them shows a friendly message with a link to serverflesk.es.

## Requirements

- A **clean** Ubuntu **24.04 LTS** server (VPS or dedicated), root access. No Plesk/cPanel/Webmin.
- ≥ 2 GB free disk on `/` and `/var`, 1 GB RAM recommended.
- Public IPv4 (IPv6 optional). Ports 22, 25, 53, 80, 443, 587, 993 open.
- A domain whose `A` record points to the server (for Let's Encrypt).

## Install

```bash
git clone https://github.com/gonzalolinaresamezcua/flesk-mini.git
cd flesk-mini
sudo bash install.sh
# or, with a domain for the panel itself:
sudo PANEL_DOMAIN=panel.example.com ADMIN_EMAIL=you@example.com bash install.sh
flesk status
```

- Panel: `https://<PANEL_DOMAIN>/flesk/` or `https://<SERVER_IP>/flesk/` (self-signed until you run `flesk panel ssl <domain>`).
- User `admin`; the initial password is in `/opt/flesk/var/.panel_admin_pass` (root only).
- Configuration is generated in `/opt/flesk/config.conf` (see `config.example.conf`, `.env.example`). Never commit it.

## CLI

```bash
flesk domain add example.com
flesk dns set example.com A www 203.0.113.10
flesk ssl issue example.com
flesk mail add info@example.com   # prints PASSWORD=... once
flesk db add example.com          # prints PASSWORD=... once
flesk sftp add example.com user1  # prints PASSWORD=... once
flesk --help
```

## Screenshots

Screenshots of the Flesk panel (from serverflesk.es; the full edition has more menu items than Mini):

| Dashboard | DNS | SSL | FTP |
|---|---|---|---|
| ![](https://serverflesk.es/assets/img/capturas/en/01-dashboard.webp) | ![](https://serverflesk.es/assets/img/capturas/en/08-dns.webp) | ![](https://serverflesk.es/assets/img/capturas/en/09-ssl.webp) | ![](https://serverflesk.es/assets/img/capturas/en/11-sftp.webp) |

## Links

- Website: <https://serverflesk.es>
- Flesk Basic 1.0 (3 domains, €5/year): <https://serverflesk.es/comprar?plan=basico>
- Flesk AI 2.0 (unlimited domains + AI, €12/year): <https://serverflesk.es/comprar?plan=ia>
- Author: [digitacode.es](https://digitacode.es)

## Licence

Free to use for trial and evaluation. © serverflesk.es, all rights reserved — see [LICENSE](LICENSE).
