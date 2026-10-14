-- Flesk panel schema — MariaDB
-- Charset utf8mb4. Aplicado por install.sh de forma idempotente.

CREATE DATABASE IF NOT EXISTS fresk CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE fresk;

CREATE TABLE IF NOT EXISTS domains (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  name          VARCHAR(253) NOT NULL,
  php_version   VARCHAR(8)   NOT NULL DEFAULT '8.3',
  ipv4          VARCHAR(45)  NULL,
  ipv6          VARCHAR(45)  NULL,
  docroot       VARCHAR(512) NOT NULL,
  status        ENUM('active','disabled') NOT NULL DEFAULT 'active',
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_domains_name (name)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS mailboxes (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  domain_id     INT UNSIGNED NOT NULL,
  local_part    VARCHAR(64)  NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  quota_mb      INT UNSIGNED NOT NULL DEFAULT 1024,
  maildir       VARCHAR(512) NOT NULL,
  active        TINYINT(1)   NOT NULL DEFAULT 1,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_mailbox (domain_id, local_part),
  CONSTRAINT fk_mailboxes_domain FOREIGN KEY (domain_id) REFERENCES domains(id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- Contestador automático por buzón (Dovecot Sieve "vacation"; rc3)
CREATE TABLE IF NOT EXISTS mail_vacation (
  mailbox_id    INT UNSIGNED NOT NULL PRIMARY KEY,
  enabled       TINYINT(1)   NOT NULL DEFAULT 0,
  subject       VARCHAR(255) NOT NULL DEFAULT '',
  body          MEDIUMTEXT   NOT NULL,
  is_html       TINYINT(1)   NOT NULL DEFAULT 0,
  start_date    DATE NULL,
  end_date      DATE NULL,
  updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_vacation_mailbox FOREIGN KEY (mailbox_id) REFERENCES mailboxes(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS aliases (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  domain_id     INT UNSIGNED NOT NULL,
  source        VARCHAR(255) NOT NULL,
  destination   VARCHAR(255) NOT NULL,
  active        TINYINT(1)   NOT NULL DEFAULT 1,
  KEY idx_aliases_source (source),
  CONSTRAINT fk_aliases_domain FOREIGN KEY (domain_id) REFERENCES domains(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS forwards (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  mailbox_id    INT UNSIGNED NOT NULL,
  destination   VARCHAR(255) NOT NULL,
  active        TINYINT(1)   NOT NULL DEFAULT 1,
  CONSTRAINT fk_forwards_mailbox FOREIGN KEY (mailbox_id) REFERENCES mailboxes(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS dns_records (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  domain_id     INT UNSIGNED NOT NULL,
  type          ENUM('A','AAAA','CNAME','MX','TXT','NS') NOT NULL,
  host          VARCHAR(255) NOT NULL DEFAULT '@',
  value         VARCHAR(1024) NOT NULL,
  ttl           INT UNSIGNED NOT NULL DEFAULT 3600,
  UNIQUE KEY uq_dns (domain_id, type, host, value(191)),
  CONSTRAINT fk_dns_domain FOREIGN KEY (domain_id) REFERENCES domains(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `databases` (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  domain_id     INT UNSIGNED NOT NULL,
  db_name       VARCHAR(64)  NOT NULL,
  db_user       VARCHAR(32)  NOT NULL,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_databases_name (db_name),
  CONSTRAINT fk_databases_domain FOREIGN KEY (domain_id) REFERENCES domains(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS sftp_users (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  domain_id     INT UNSIGNED NOT NULL,
  username      VARCHAR(32)  NOT NULL,
  system_user   VARCHAR(32)  NOT NULL,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_sftp_username (username),
  CONSTRAINT fk_sftp_domain FOREIGN KEY (domain_id) REFERENCES domains(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS ssl_certs (
  id              INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  domain_id       INT UNSIGNED NOT NULL,
  issuer          VARCHAR(128) NOT NULL DEFAULT 'letsencrypt',
  not_after       DATETIME NULL,
  path_fullchain  VARCHAR(512) NOT NULL,
  path_key        VARCHAR(512) NOT NULL,
  status          ENUM('pending','active','expired','error') NOT NULL DEFAULT 'pending',
  UNIQUE KEY uq_ssl_domain (domain_id),
  CONSTRAINT fk_ssl_domain FOREIGN KEY (domain_id) REFERENCES domains(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS audit_log (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  actor         VARCHAR(64)  NOT NULL DEFAULT 'cli',
  action        VARCHAR(64)  NOT NULL,
  target        VARCHAR(255) NULL,
  result        VARCHAR(32)  NOT NULL,
  detail        TEXT NULL,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_audit_created (created_at)
) ENGINE=InnoDB;

-- Admins de la UI (fase 8). Creada ya para no migrar después.
CREATE TABLE IF NOT EXISTS admins (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  username      VARCHAR(64)  NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  email         VARCHAR(255) NULL,
  active        TINYINT(1)   NOT NULL DEFAULT 1,
  failed_logins INT UNSIGNED NOT NULL DEFAULT 0,
  locked_until  DATETIME NULL,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_admins_username (username)
) ENGINE=InnoDB;

-- Migración 1.0.0-rc2: menú de usuario (idioma, último acceso) y perfil del cliente. Idempotente (MariaDB).
ALTER TABLE admins ADD COLUMN IF NOT EXISTS language VARCHAR(5) NOT NULL DEFAULT 'es' AFTER email;
ALTER TABLE admins ADD COLUMN IF NOT EXISTS last_login_at DATETIME NULL AFTER locked_until;

-- Perfil (datos del cliente): una sola fila id=1
CREATE TABLE IF NOT EXISTS panel_profile (
  id            TINYINT UNSIGNED NOT NULL PRIMARY KEY,
  company       VARCHAR(190) NOT NULL DEFAULT '',
  tax_id        VARCHAR(32)  NOT NULL DEFAULT '',
  contact_name  VARCHAR(190) NOT NULL DEFAULT '',
  email         VARCHAR(190) NOT NULL DEFAULT '',
  phone         VARCHAR(40)  NOT NULL DEFAULT '',
  address       VARCHAR(255) NOT NULL DEFAULT '',
  city          VARCHAR(120) NOT NULL DEFAULT '',
  postal_code   VARCHAR(16)  NOT NULL DEFAULT '',
  country       VARCHAR(120) NOT NULL DEFAULT '',
  website       VARCHAR(255) NOT NULL DEFAULT '',
  notes         TEXT NULL,
  updated_by    VARCHAR(64)  NULL,
  updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;
INSERT IGNORE INTO panel_profile (id, country) VALUES (1, 'España');

-- Vistas útiles para Postfix/Dovecot (maps SQL)
CREATE OR REPLACE VIEW v_virtual_domains AS
  SELECT name AS domain FROM domains WHERE status = 'active';

CREATE OR REPLACE VIEW v_virtual_mailboxes AS
  SELECT CONCAT(m.local_part, '@', d.name) AS email,
         m.maildir AS maildir,
         m.password_hash AS password,
         m.quota_mb * 1024 * 1024 AS quota,
         m.active AS active
  FROM mailboxes m
  JOIN domains d ON d.id = m.domain_id
  WHERE d.status = 'active';

CREATE OR REPLACE VIEW v_virtual_aliases AS
  SELECT a.source AS email, a.destination AS destination
  FROM aliases a
  JOIN domains d ON d.id = a.domain_id
  WHERE a.active = 1 AND d.status = 'active'
  UNION ALL
  -- Reenvío: conserva copia local (origen,destino-externo)
  SELECT CONCAT(m.local_part, '@', d.name) AS email,
         CONCAT(m.local_part, '@', d.name, ',', f.destination) AS destination
  FROM forwards f
  JOIN mailboxes m ON m.id = f.mailbox_id
  JOIN domains d ON d.id = m.domain_id
  WHERE f.active = 1 AND m.active = 1 AND d.status = 'active';

-- ---------------------------------------------------------------- rc2: SSL método/nombres/aviso
ALTER TABLE ssl_certs ADD COLUMN IF NOT EXISTS method VARCHAR(16) NULL AFTER status;
ALTER TABLE ssl_certs ADD COLUMN IF NOT EXISTS names VARCHAR(1024) NULL AFTER method;
ALTER TABLE ssl_certs ADD COLUMN IF NOT EXISTS note VARCHAR(512) NULL AFTER names;

-- SGBD: caché de la aplicación/versión detectada por base (flesk db appinfo; botón "Refrescar")
CREATE TABLE IF NOT EXISTS db_app_cache (
  db_name     VARCHAR(64)  NOT NULL PRIMARY KEY,
  app         VARCHAR(32)  NULL,
  app_name    VARCHAR(64)  NULL,
  version     VARCHAR(32)  NULL,
  path        VARCHAR(255) NULL,
  url         VARCHAR(255) NULL,
  source      VARCHAR(64)  NULL,
  tables_count INT UNSIGNED NOT NULL DEFAULT 0,
  note        VARCHAR(32)  NULL,
  detected_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


