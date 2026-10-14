<?php
/**
 * Flesk — detección de la aplicación que usa cada base de datos de sitio (columna "Aplicación" de SGBD).
 * Lo ejecuta scripts/db-appinfo.sh como root ("flesk db appinfo [<base>]"); imprime JSON.
 * Fuentes, por orden de fiabilidad:
 *   1. Configuración de la app en el árbol del dominio que apunta a esa base (wp-config.php, parameters.php, conf.php…).
 *   2. Registro de instalaciones del panel (audit_log app.install / pkg.install, con db= o por proximidad a db.add).
 *   3. Inspección de la base (wp_options, ps_configuration, llx_const, config, mdl_config…).
 * Nunca ejecuta código de las aplicaciones (solo lee y aplica expresiones regulares) y nunca devuelve contraseñas.
 */
declare(strict_types=1);

const APPS = [
    'wordpress' => 'WordPress', 'prestashop' => 'PrestaShop', 'drupal' => 'Drupal', 'dolibarr' => 'Dolibarr',
    'suitecrm' => 'SuiteCRM', 'espocrm' => 'EspoCRM', 'kanboard' => 'Kanboard', 'joomla' => 'Joomla!',
    'nextcloud' => 'Nextcloud', 'moodle' => 'Moodle', 'matomo' => 'Matomo', 'phpbb' => 'phpBB', 'mediawiki' => 'MediaWiki',
];

function cfg(): array {
    $c = [];
    foreach (@file('/opt/flesk/config.conf', FILE_IGNORE_NEW_LINES) ?: [] as $l) {
        if (preg_match('/^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/', $l, $m)) $c[$m[1]] = trim($m[2], "\"'");
    }
    return $c;
}
function admin_pdo(): PDO {
    $c = cfg();
    $pass = trim((string)@file_get_contents($c['DB_ADMIN_PASS_FILE'] ?? '/opt/flesk/var/.dbadminpass'));
    return new PDO('mysql:host=' . ($c['DB_HOST'] ?? '127.0.0.1') . ';charset=utf8mb4', $c['DB_ADMIN_USER'] ?? 'fresk_admin', $pass,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC, PDO::ATTR_TIMEOUT => 5]);
}
function clean(?string $s, int $max = 64): ?string {
    if ($s === null) return null;
    $s = trim(preg_replace('/[^\P{C}]+/u', '', $s) ?? '');
    return $s === '' ? null : mb_substr($s, 0, $max);
}
function ver(?string $s): ?string {
    if ($s === null) return null;
    return preg_match('/\d+(\.\d+){1,3}([.-]?(rc|beta|alpha|dev)\d*)?/i', $s, $m) ? $m[0] : null;
}
function rd(string $f): string {
    if (!is_file($f) || is_link($f) || filesize($f) > 1048576) return '';
    return (string)@file_get_contents($f);
}
function rx(string $txt, string $re): ?string { return preg_match($re, $txt, $m) ? $m[1] : null; }

/** Firmas de configuración: [app, archivo de config relativo, regex del nombre de BD, fn versión]. */
function signatures(): array {
    $q = '[\'"]';
    return [
        ['wordpress', 'wp-config.php', "/define\\(\\s*{$q}DB_NAME{$q}\\s*,\\s*{$q}([^'\"]+){$q}/",
            fn($d) => rx(rd("$d/wp-includes/version.php"), "/\\\$wp_version\\s*=\\s*{$q}([^'\"]+){$q}/")],
        ['prestashop', 'app/config/parameters.php', "/{$q}database_name{$q}\\s*=>\\s*{$q}([^'\"]+){$q}/",
            fn($d) => rx(rd("$d/app/AppKernel.php"), "/const\\s+VERSION\\s*=\\s*{$q}([^'\"]+){$q}/")
                ?? rx(rd("$d/src/Core/Version.php"), "/{$q}(\\d+\\.\\d+\\.\\d+(?:\\.\\d+)?){$q}/")],
        ['prestashop', 'config/settings.inc.php', "/define\\(\\s*{$q}_DB_NAME_{$q}\\s*,\\s*{$q}([^'\"]+){$q}/",
            fn($d) => rx(rd("$d/config/settings.inc.php"), "/_PS_VERSION_{$q}\\s*,\\s*{$q}([^'\"]+){$q}/")],
        ['dolibarr', 'conf/conf.php', "/\\\$dolibarr_main_db_name\\s*=\\s*{$q}([^'\"]+){$q}/",
            fn($d) => rx(rd("$d/filefunc.inc.php"), "/define\\(\\s*{$q}DOL_VERSION{$q}\\s*,\\s*{$q}([^'\"]+){$q}/")],
        ['drupal', 'sites/default/settings.php', "/^\\s*{$q}database{$q}\\s*=>\\s*{$q}([^'\"]+){$q}/m",
            fn($d) => rx(rd("$d/core/lib/Drupal.php"), "/const\\s+VERSION\\s*=\\s*{$q}([^'\"]+){$q}/")],
        ['suitecrm', 'public/legacy/config.php', "/{$q}db_name{$q}\\s*=>\\s*{$q}([^'\"]+){$q}/",
            fn($d) => rx(rd("$d/VERSION"), '/^\s*(\S+)/') ?? rx(rd("$d/public/legacy/suitecrm_version.php"), "/\\\$suitecrm_version\\s*=\\s*{$q}([^'\"]+){$q}/")],
        ['suitecrm', 'config.php', "/{$q}db_name{$q}\\s*=>\\s*{$q}([^'\"]+){$q}/",
            fn($d) => is_file("$d/suitecrm_version.php") ? rx(rd("$d/suitecrm_version.php"), "/\\\$suitecrm_version\\s*=\\s*{$q}([^'\"]+){$q}/") : null, 'suitecrm_version.php'],
        ['espocrm', 'data/config-internal.php', "/{$q}dbname{$q}\\s*=>\\s*{$q}([^'\"]+){$q}/",
            fn($d) => rx(rd("$d/data/config.php"), "/{$q}version{$q}\\s*=>\\s*{$q}([^'\"]+){$q}/")],
        ['kanboard', 'config.php', "/define\\(\\s*{$q}DB_NAME{$q}\\s*,\\s*{$q}([^'\"]+){$q}/",
            fn($d) => ver(rx(rd("$d/app/constants.php"), "/APP_VERSION{$q}\\s*,\\s*[^'\"]*{$q}([^'\"]+){$q}/")), 'app/constants.php'],
        ['joomla', 'configuration.php', "/public\\s+\\\$db\\s*=\\s*{$q}([^'\"]+){$q}/",
            fn($d) => (($a = rx($t = rd("$d/libraries/src/Version.php"), '/MAJOR_VERSION\s*=\s*(\d+)/')) !== null)
                ? $a . '.' . rx($t, '/MINOR_VERSION\s*=\s*(\d+)/') . '.' . rx($t, '/PATCH_VERSION\s*=\s*(\d+)/') : null],
        ['nextcloud', 'config/config.php', "/{$q}dbname{$q}\\s*=>\\s*{$q}([^'\"]+){$q}/",
            fn($d) => rx(rd("$d/version.php"), "/\\\$OC_VersionString\\s*=\\s*{$q}([^'\"]+){$q}/"), 'version.php'],
        ['moodle', 'config.php', "/\\\$CFG->dbname\\s*=\\s*{$q}([^'\"]+){$q}/",
            fn($d) => ver(rx(rd("$d/version.php"), "/\\\$release\\s*=\\s*{$q}([^'\"]+){$q}/"))],
        ['matomo', 'config/config.ini.php', '/^\s*dbname\s*=\s*"?([^"\r\n]+)"?/m',
            fn($d) => rx(rd("$d/core/Version.php"), "/const\\s+VERSION\\s*=\\s*{$q}([^'\"]+){$q}/")],
    ];
}

/** Recorre httpdocs/apps/private del dominio (profundidad ≤ 5) buscando configs de apps. @return array<string,array> por base */
function scan_configs(string $domain, string $docroot): array {
    $root = '/var/www/vhosts/' . $domain;
    if (!preg_match('/^[a-z0-9.-]+$/', $domain) || !is_dir($root)) return [];
    $skip = ['wp-content', 'node_modules', 'vendor', 'cache', 'var', 'img', 'upload', 'uploads', 'documents', 'tmp', 'logs', '.git', 'modules', 'themes', 'plugins', 'translations', 'js', 'css', 'mails', 'pdf', 'download'];
    $found = [];
    $queue = [];
    foreach (['httpdocs', 'apps', 'private'] as $b) if (is_dir("$root/$b") && !is_link("$root/$b")) $queue[] = ["$root/$b", 0];
    $seen = 0;
    while ($queue && $seen < 4000) {
        [$dir, $depth] = array_shift($queue);
        $seen++;
        foreach (signatures() as $sig) {
            [$app, $file, $re, $vfn] = $sig;
            $marker = $sig[4] ?? null;
            if ($marker !== null && !is_file("$dir/$marker")) continue;
            $txt = rd("$dir/$file");
            if ($txt === '' || !preg_match($re, $txt, $m)) continue;
            $db = strtolower(trim($m[1]));
            if (!preg_match('/^db_[a-z0-9_]+$/', $db) || isset($found[$db])) continue;
            $rel = substr($dir, strlen($root) + 1);
            $url = null;
            if (str_starts_with($rel . '/', 'httpdocs/')) {
                $p = substr($rel, 8);
                // Dolibarr/SuiteCRM 8/Espo… con carpeta pública: la URL es la del directorio publicado
                $url = 'https://' . $domain . ($p === '' ? '/' : $p . '/');
            }
            $found[$db] = ['app' => $app, 'path' => '/' . $rel, 'url' => $url, 'version' => clean(ver($vfn($dir)) ?? $vfn($dir), 32), 'source' => 'config'];
            break;
        }
        if ($depth >= 5) continue;
        $subs = @scandir($dir) ?: [];
        foreach ($subs as $s) {
            if ($s === '.' || $s === '..' || in_array(strtolower($s), $skip, true)) continue;
            $p = "$dir/$s";
            if (is_dir($p) && !is_link($p)) $queue[] = [$p, $depth + 1];
        }
    }
    return $found;
}

/** Inspección de la base (solo SELECT de metadatos/opciones). */
function inspect_db(PDO $pdo, string $db): array {
    $st = $pdo->prepare('SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = ?');
    $st->execute([$db]);
    $tables = array_map('strval', $st->fetchAll(PDO::FETCH_COLUMN));
    $out = ['tables' => count($tables)];
    if (!$tables) return $out;
    $set = array_flip($tables);
    $T = static fn(string $t) => '`' . $db . '`.`' . str_replace('`', '', $t) . '`';
    $one = static function (string $sql, array $p = []) use ($pdo) { try { $s = $pdo->prepare($sql); $s->execute($p); $v = $s->fetchColumn(); return $v === false ? null : (string)$v; } catch (Throwable $e) { return null; } };
    foreach ($tables as $t) {
        // WordPress: <prefijo>options con siteurl
        if (preg_match('/^(.*)options$/', $t, $m) && isset($set[$m[1] . 'posts'])) {
            $site = $one('SELECT option_value FROM ' . $T($t) . " WHERE option_name='siteurl'");
            if ($site !== null) return $out + ['app' => 'wordpress', 'url' => clean($site, 255), 'dbver' => $one('SELECT option_value FROM ' . $T($t) . " WHERE option_name='db_version'")];
        }
        // PrestaShop: <prefijo>configuration PS_VERSION_DB
        if (preg_match('/^(.*)configuration$/', $t, $m) && isset($set[$m[1] . 'shop'])) {
            $v = $one('SELECT value FROM ' . $T($t) . " WHERE name='PS_VERSION_DB' LIMIT 1");
            $dom = $one('SELECT value FROM ' . $T($t) . " WHERE name='PS_SHOP_DOMAIN_SSL' LIMIT 1") ?? $one('SELECT value FROM ' . $T($t) . " WHERE name='PS_SHOP_DOMAIN' LIMIT 1");
            $uri = $one('SELECT physical_uri FROM ' . $T($m[1] . 'shop_url') . ' WHERE main=1 LIMIT 1');
            return $out + ['app' => 'prestashop', 'version' => ver($v), 'url' => $dom ? clean('https://' . $dom . ($uri ?? '/'), 255) : null];
        }
        // Dolibarr: llx_const MAIN_VERSION_LAST_UPGRADE / INSTALL
        if (preg_match('/^(.*)const$/', $t, $m) && isset($set[$m[1] . 'societe'])) {
            $v = $one('SELECT value FROM ' . $T($t) . " WHERE name='MAIN_VERSION_LAST_UPGRADE' AND value<>'' LIMIT 1")
                ?? $one('SELECT value FROM ' . $T($t) . " WHERE name='MAIN_VERSION_LAST_INSTALL' LIMIT 1");
            return $out + ['app' => 'dolibarr', 'version' => ver($v)];
        }
        // Moodle: mdl_config release
        if (preg_match('/^(.*)config$/', $t, $m) && isset($set[$m[1] . 'course'], $set[$m[1] . 'config_plugins'])) {
            return $out + ['app' => 'moodle', 'version' => ver($one('SELECT value FROM ' . $T($t) . " WHERE name='release'"))];
        }
        // Joomla: <prefijo>extensions + schemas
        if (preg_match('/^(.*)extensions$/', $t, $m) && isset($set[$m[1] . 'schemas'])) {
            $mc = $one('SELECT manifest_cache FROM ' . $T($t) . " WHERE element='joomla' AND type='file' LIMIT 1");
            $j = $mc ? json_decode($mc, true) : null;
            return $out + ['app' => 'joomla', 'version' => ver(is_array($j) ? (string)($j['version'] ?? '') : null)];
        }
        // Matomo: <prefijo>option version_core
        if (preg_match('/^(.*)option$/', $t, $m) && isset($set[$m[1] . 'log_visit'])) {
            return $out + ['app' => 'matomo', 'version' => ver($one('SELECT option_value FROM ' . $T($t) . " WHERE option_name='version_core'"))];
        }
        // Nextcloud: oc_appconfig core
        if (preg_match('/^(.*)appconfig$/', $t, $m) && isset($set[$m[1] . 'filecache'])) {
            return $out + ['app' => 'nextcloud', 'version' => ver($one('SELECT configvalue FROM ' . $T($t) . " WHERE appid='core' AND configkey='vendor_version'"))];
        }
        // phpBB: <prefijo>config version
        if (preg_match('/^(.*)config$/', $t, $m) && isset($set[$m[1] . 'posts'], $set[$m[1] . 'forums'])) {
            return $out + ['app' => 'phpbb', 'version' => ver($one('SELECT config_value FROM ' . $T($t) . " WHERE config_name='version'"))];
        }
    }
    if (isset($set['config'], $set['users'], $set['accounts'])) {
        // SuiteCRM 7/8 (núcleo SugarCRM CE): config info/sugar_version (+ suitecrm_version si existe)
        $v = $one('SELECT value FROM ' . $T('config') . " WHERE category='info' AND name='suitecrm_version'");
        return $out + ['app' => 'suitecrm', 'version' => ver($v)];
    }
    if (isset($set['scheduled_job_log_record'], $set['entity_team'])) return $out + ['app' => 'espocrm'];
    if (isset($set['key_value'], $set['config'], $set['users_field_data'])) return $out + ['app' => 'drupal'];
    if (isset($set['project_has_users'], $set['swimlanes'])) return $out + ['app' => 'kanboard'];
    if (isset($set['updatelog'], $set['page'], $set['revision'])) return $out + ['app' => 'mediawiki'];
    return $out;
}

/** Registro de instalaciones del panel → [db => info]. */
function registry(PDO $pdo, string $fdb): array {
    $rows = $pdo->query("SELECT id, UNIX_TIMESTAMP(created_at) AS ts, action, target, result, detail FROM `$fdb`.audit_log
        WHERE action IN ('db.add','app.install','pkg.install') AND result='ok' ORDER BY id")->fetchAll();
    $adds = [];
    $out = [];
    foreach ($rows as $r) {
        $detail = (string)$r['detail'];
        if ($r['action'] === 'db.add') {
            if (preg_match('/\bdb=(db_[a-z0-9_]+)/', $detail, $m)) $adds[] = ['db' => $m[1], 'domain' => (string)$r['target'], 'ts' => (int)$r['ts']];
            continue;
        }
        $app = null; $path = null; $verReg = null; $domain = null;
        if ($r['action'] === 'app.install' && preg_match('/^([a-z0-9.-]+):([a-z0-9_-]+)$/', (string)$r['target'], $m)) {
            [$domain, $app] = [$m[1], $m[2]];
            $path = preg_match('#path=(/\S*)#', $detail, $mm) ? $mm[1] : '/';
        } elseif ($r['action'] === 'pkg.install' && preg_match('#^([a-z0-9.-]+):(/\S*)$#', (string)$r['target'], $m)) {
            [$domain, $path] = [$m[1], $m[2]];
            $url = preg_match('#(https://\S+)#', $detail, $mm) ? strtolower($mm[1]) : '';
            foreach (array_keys(APPS) as $k) if (str_contains($url, $k)) { $app = $k; break; }
            $app ??= 'pkg';
            $verReg = ver(preg_replace('#^https://[^/]+#', '', $url));
        }
        if ($app === null) continue;
        $db = preg_match('/\bdb=(db_[a-z0-9_]+)/', $detail, $mm) ? $mm[1] : null;
        if ($db === null) {
            // Sin db= (registros antiguos): la base creada para ese dominio justo antes (≤ 15 min) de esta instalación
            for ($i = count($adds) - 1; $i >= 0; $i--) {
                $a = $adds[$i];
                if ($a['domain'] === $domain && $a['ts'] <= (int)$r['ts'] && (int)$r['ts'] - $a['ts'] <= 900) { $db = $a['db']; array_splice($adds, $i, 1); break; }
            }
        }
        if ($db !== null) $out[$db] = ['app' => $app, 'path' => '/httpdocs' . rtrim($path, '/'), 'url' => 'https://' . $domain . rtrim($path, '/') . '/', 'version' => $verReg, 'source' => 'registro'];
    }
    return $out;
}

$only = $argv[1] ?? '';
if ($only !== '' && !preg_match('/^db_[a-z0-9_]{1,61}$/', $only)) { fwrite(STDERR, "base inválida\n"); exit(2); }
$pdo = admin_pdo();
$fdb = preg_replace('/[^A-Za-z0-9_]/', '', cfg()['DB_NAME'] ?? 'fresk');
$sql = "SELECT db.db_name, d.name AS domain, d.docroot FROM `$fdb`.`databases` db JOIN `$fdb`.domains d ON d.id = db.domain_id";
$list = $pdo->query($sql)->fetchAll();
$reg = registry($pdo, $fdb);
$cfgCache = [];
$res = [];
foreach ($list as $row) {
    $db = (string)$row['db_name'];
    if ($only !== '' && $db !== $only) continue;
    $dom = (string)$row['domain'];
    $cfgCache[$dom] ??= scan_configs($dom, (string)$row['docroot']);
    $c = $cfgCache[$dom][$db] ?? null;
    $r = $reg[$db] ?? null;
    $i = inspect_db($pdo, $db);
    $app = $c['app'] ?? ($r !== null && $r['app'] !== 'pkg' ? $r['app'] : null) ?? ($i['app'] ?? null);
    $sources = array_values(array_filter([$c ? 'config' : null, $r ? 'registro' : null, isset($i['app']) ? 'base' : null]));
    $version = $c['version'] ?? ($i['version'] ?? null) ?? ($r['version'] ?? null);
    $note = null;
    if ($app !== null && ($i['tables'] ?? 0) === 0) $note = 'empty';
    elseif ($app === 'wordpress' && $version === null && !empty($i['dbver'])) $version = 'db ' . clean($i['dbver'], 16);
    if ($app === null && $r !== null) { $app = 'pkg'; }
    $res[] = [
        'db' => $db,
        'app' => $app,
        'name' => $app === null ? null : (APPS[$app] ?? ($app === 'pkg' ? 'Instalación libre' : ucfirst($app))),
        'version' => clean($version, 32),
        'path' => clean($c['path'] ?? $r['path'] ?? null, 255),
        'url' => clean($c['url'] ?? ($i['url'] ?? null) ?? $r['url'] ?? null, 255),
        'source' => implode('+', $sources) ?: null,
        'tables' => (int)($i['tables'] ?? 0),
        'note' => $note,
    ];
}
echo json_encode($res, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), "\n";
