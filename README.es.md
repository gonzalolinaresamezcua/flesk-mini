<p align="center"><img src="docs/logo.svg" width="96" alt="Logo Flesk"></p>

<h1 align="center">Flesk Mini</h1>
<p align="center"><b>Edición de prueba gratuita del panel de hosting Flesk — 1 dominio</b><br>
<a href="https://serverflesk.es">serverflesk.es</a> · <a href="README.md">Read in English</a></p>

---

Flesk Mini es un panel de hosting ligero y autoalojado para **un servidor Ubuntu 24.04 y un dominio**.
Te permite probar Flesk de verdad: web, archivos, DNS, correo, SSL, base de datos y SFTP/FTP, desde un panel web bilingüe (ES/EN).

> **¿Necesitas más de un dominio?** En [serverflesk.es](https://serverflesk.es):
> - **Flesk Básico 1.0** — hasta **3 dominios**, licencia anual de **5 €/año** (IVA incl.) — [comprar](https://serverflesk.es/comprar?plan=basico).
> - **Flesk IA 2.0** — **dominios ilimitados** con **inteligencia artificial operativa** que gestiona el servidor por ti, licencia anual de **12 €/año** (IVA incl.) — [comprar](https://serverflesk.es/comprar?plan=ia).

## Funciones

| Menú | Qué hace |
|------|----------|
| Dashboard | Resumen de tu dominio, buzón, SSL y base de datos |
| Dominio | Alta del dominio (vhost nginx + pool PHP-FPM aislado por dominio) |
| Archivos | Gestor de archivos web (subir, editar, comprimir, permisos) |
| DNS | Zona BIND autoritativa del dominio (A, AAAA, CNAME, MX, TXT…), DKIM |
| Correo | 1 buzón (Postfix + Dovecot), alias/reenvíos, contestador, webmail Roundcube |
| SSL | Certificado Let's Encrypt del dominio con renovación automática |
| Base de datos | 1 base MariaDB + Adminer con acceso de un solo uso |
| FTP | 1 usuario SFTP enjaulado; el panel muestra un host de conexión que funciona (`ftp.<dominio>` → `<dominio>` → IP del servidor) |

Además: interfaz en español/inglés con selector de idioma (español por defecto), protección CSRF, bloqueo de login, captcha, registro de auditoría y la CLI `flesk`.

## Límites de la prueba

| Recurso | Flesk Mini (gratis) | Flesk Básico (5 €/año) | Flesk IA (12 €/año) |
|---------|-----------:|---------------:|--------------:|
| Dominios | 1 | 3 | Ilimitados |
| Buzones de correo | 1 | ✔ | ✔ |
| Certificados SSL | 1 | ✔ | ✔ |
| Bases de datos | 1 | ✔ | ✔ |
| Usuarios SFTP/FTP | 1 | ✔ | ✔ |
| Copias, estadísticas, instalador de apps, GitHub | — | ver web | ✔ |
| Inteligencia artificial | — | — | ✔ |

Los límites los aplica el propio motor (`lib/limits.sh`, usado por `domain add`, `mail add`, `db add`, `sftp add` y `ssl issue`) y el panel web los vuelve a comprobar (`web/public/includes/limits.php`). Al superarlos se muestra un aviso con enlace a serverflesk.es.

## Requisitos

- Servidor Ubuntu **24.04 LTS limpio** (VPS o dedicado) con acceso root. Sin Plesk/cPanel/Webmin.
- ≥ 2 GB libres en `/` y `/var`; 1 GB de RAM recomendado.
- IPv4 pública (IPv6 opcional). Puertos 22, 25, 53, 80, 443, 587 y 993 abiertos.
- Un dominio con registro `A` apuntando al servidor (para Let's Encrypt).

## Instalación

```bash
git clone https://github.com/gonzalolinaresamezcua/flesk-mini.git
cd flesk-mini
sudo bash install.sh
# o con dominio propio para el panel:
sudo PANEL_DOMAIN=panel.ejemplo.com ADMIN_EMAIL=tu@ejemplo.com bash install.sh
flesk status
```

- Panel: `https://<PANEL_DOMAIN>/flesk/` o `https://<IP_DEL_SERVIDOR>/flesk/` (autofirmado hasta ejecutar `flesk panel ssl <dominio>`).
- Usuario `admin`; la contraseña inicial está en `/opt/flesk/var/.panel_admin_pass` (solo root).
- La configuración se genera en `/opt/flesk/config.conf` (ver `config.example.conf` y `.env.example`). No la subas nunca al repositorio.

## CLI

```bash
flesk domain add ejemplo.com
flesk dns set ejemplo.com A www 203.0.113.10
flesk ssl issue ejemplo.com
flesk mail add info@ejemplo.com   # muestra PASSWORD=... una vez
flesk db add ejemplo.com          # muestra PASSWORD=... una vez
flesk sftp add ejemplo.com user1  # muestra PASSWORD=... una vez
flesk --help
```

## Capturas

Capturas del panel Flesk (de serverflesk.es; la edición completa tiene más opciones de menú que Mini):

| Dashboard | DNS | SSL | FTP |
|---|---|---|---|
| ![](https://serverflesk.es/assets/img/capturas/01-dashboard.webp) | ![](https://serverflesk.es/assets/img/capturas/08-dns.webp) | ![](https://serverflesk.es/assets/img/capturas/09-ssl.webp) | ![](https://serverflesk.es/assets/img/capturas/11-sftp.webp) |

## Enlaces

- Web: <https://serverflesk.es>
- Flesk Básico 1.0 (3 dominios, 5 €/año): <https://serverflesk.es/comprar?plan=basico>
- Flesk IA 2.0 (dominios ilimitados + IA, 12 €/año): <https://serverflesk.es/comprar?plan=ia>
- Autor: [digitacode.es](https://digitacode.es)

## Licencia

Uso gratuito para prueba y evaluación. © serverflesk.es, todos los derechos reservados — ver [LICENSE](LICENSE).
