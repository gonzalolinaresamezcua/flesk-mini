# Changelog — Flesk Mini

## 1.0.1-mini (2026-10-16)
- **Seguridad nginx por defecto**: bloqueo de descarga web de ficheros sensibles (`.dat`, `.sql`, `.zip`/`.tar`/`.gz`/`.tgz`, `.bak`/`.old`/`.backup`, `.log`, `.env`, `.ini`, `.sh`) y ficheros ocultos; `autoindex off`. ACME (`/.well-known/acme-challenge/`) permitido. No se bloquea `.json`.

## 1.0.0-mini (2026-10-14)
- Primera publicación de Flesk Mini (1 dominio, panel ES/EN, CLI, correo, DNS, SSL, BD, SFTP).
