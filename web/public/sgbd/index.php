<?php
/**
 * Flesk: Adminer (SGBD web) detrás de la sesión del panel.
 * - Sin sesión válida del panel → redirección al login. Adminer no es accesible por URL (web/vendor).
 * - Solo MySQL/MariaDB en localhost (el campo servidor se oculta y se fuerza).
 * - Login con usuario/contraseña de la base (nunca contraseña en la URL), antifuerza bruta de Adminer.
 * - "Abrir" desde SGBD (SSO): ?flesk_sso=<token> de un solo uso (60 s) emitido por db.php tras POST+CSRF,
 *   guardado solo como hash en la sesión del panel y ligado a ese admin y a esa base. Al canjearlo,
 *   `flesk db login <base>` (sudo) crea una cuenta MariaDB efímera fks_* con privilegios solo sobre esa
 *   base; su contraseña se inyecta en el login de Adminer en el servidor (nunca va al navegador) y
 *   se borra con el logout de Adminer/panel o al caducar (flesk-sgbd-purge.timer).
 * - noindex, X-Frame-Options DENY (Adminer), sin comprobación de versión externa.
 */
require dirname(__DIR__) . '/auth.php';
if (empty($_SESSION['fresk_admin_id'])) {
    header('Location: ' . fresk_base() . '/login.php', true, 302);
    exit;
}
/** Respuesta de rechazo (token inválido/caducado/reutilizado o fallo al crear la credencial). */
function flesk_sgbd_reject(string $msg, int $code): void
{
    http_response_code($code);
    header('Cache-Control: no-store');
    header('Content-Type: text/html; charset=utf-8');
    header('X-Robots-Tag: noindex, nofollow');
    echo '<!doctype html><meta charset="utf-8"><title>Flesk · SGBD</title>'
        . '<body style="font-family:system-ui,sans-serif;margin:3rem"><h1 style="font-size:1.2rem">Flesk · SGBD</h1><p>'
        . fresk_h($msg) . '</p><p><a href="' . fresk_h(fresk_base() . '/db.php') . '">← SGBD</a></p></body>';
    exit;
}

$fleskSso = null;
if (isset($_GET['flesk_sso'])) {
    $ssoDb = fresk_sgbd_consume_token((string)$_GET['flesk_sso']); // un solo uso: se invalida siempre
    if ($ssoDb === null || !fresk_db_registered($ssoDb)) {
        fresk_audit('sgbd.open', $ssoDb ?? '', 'fail', 'token inválido, caducado o reutilizado');
        flesk_sgbd_reject(t('db.sso_invalid'), 403);
    }
    $r = fresk_cli(['db', 'login', $ssoDb]);
    if ($r['code'] !== 0 || empty($r['password'])
        || !preg_match('/^USER=(fks_[0-9]{10}_[a-f0-9]{10})$/m', $r['stdout'], $um)
        || !preg_match('/^EXPIRES=([0-9]{10})$/m', $r['stdout'], $em)) {
        fresk_audit('sgbd.open', $ssoDb, 'fail', 'flesk db login rc=' . $r['code']);
        flesk_sgbd_reject(t('db.sso_failed'), 500);
    }
    $eph = is_array($_SESSION['flesk_sgbd_eph'] ?? null) ? $_SESSION['flesk_sgbd_eph'] : [];
    $eph[$um[1]] = (int)$em[1];
    $_SESSION['flesk_sgbd_eph'] = $eph;
    fresk_audit('sgbd.open', $ssoDb, 'ok', 'user=' . $um[1]);
    $fleskSso = ['username' => $um[1], 'password' => (string)$r['password'], 'db' => $ssoDb];
    unset($r);
}
// Logout de Adminer con una credencial efímera de esta sesión: se borra la cuenta MariaDB al momento
if (isset($_POST['logout']) && is_string($_GET['username'] ?? null)
    && isset($_SESSION['flesk_sgbd_eph'][$_GET['username']])) {
    fresk_cli(['db', 'logout', (string)$_GET['username']]);
    unset($_SESSION['flesk_sgbd_eph'][$_GET['username']]);
}
$GLOBALS['flesk_admin_user'] = (string)($_SESSION['fresk_admin_user'] ?? $_SESSION['fresk_admin_username'] ?? '');
$flang = function_exists('fresk_lang') ? fresk_lang() : 'es';
session_write_close(); // Adminer abre su propia sesión (adminer_sid), con otro id
$_SESSION = [];
$asid = (string)($_COOKIE['adminer_sid'] ?? '');
session_id(preg_match('/^[A-Za-z0-9,-]{22,128}$/', $asid) ? $asid : bin2hex(random_bytes(16)));

header('X-Robots-Tag: noindex, nofollow');
// Idioma de Adminer = idioma del panel (salvo que el usuario lo cambie en Adminer)
if (!isset($_COOKIE['adminer_lang']) && in_array($flang, ['es', 'en'], true)) $_COOKIE['adminer_lang'] = $flang;
// Servidor fijo: localhost
if (isset($_GET['server'])) $_GET['server'] = 'localhost';
if (isset($_POST['auth']) && is_array($_POST['auth'])) {
    $_POST['auth']['server'] = 'localhost';
    $_POST['auth']['driver'] = 'server';
}
if ($fleskSso !== null) {
    // Login de Adminer construido en el servidor: la contraseña efímera no sale nunca hacia el navegador.
    // Adminer la guarda en su sesión (ficheros 0600 del usuario flesk) y redirige a ?server&username&db.
    $_SERVER['REQUEST_METHOD'] = 'POST';
    $_GET = ['server' => 'localhost'];
    $_SERVER['REQUEST_URI'] = strtok((string)($_SERVER['REQUEST_URI'] ?? ''), '?') . '?server=localhost';
    $_SERVER['QUERY_STRING'] = 'server=localhost';
    $_POST = ['auth' => ['driver' => 'server', 'server' => 'localhost', 'username' => $fleskSso['username'],
        'password' => $fleskSso['password'], 'db' => $fleskSso['db'], 'permanent' => '']];
    $GLOBALS['flesk_sso_login'] = true;
    $fleskSso = null;
}
foreach (['sqlite', 'sqlite2', 'pgsql', 'oracle', 'mssql', 'mongo', 'elastic', 'clickhouse', 'firebird', 'simpledb'] as $drv) unset($_GET[$drv]);

function adminer_object()
{
    return new class extends \Adminer\Adminer {
        public function name()
        {
            return "<a href='../' id='h1' title='Flesk'>Flesk · SGBD</a>";
        }
        public function credentials()
        {
            return ['localhost', (string)($_GET['username'] ?? ''), \Adminer\get_password()];
        }
        public function verifyLoginToken()
        {
            // El login SSO lo genera el propio servidor (token de un solo uso ya validado); el manual exige token
            return empty($GLOBALS['flesk_sso_login']);
        }
        public function loginFormField($name, $heading, $value)
        {
            if ($name === 'server') return "<input type='hidden' name='auth[server]' value='localhost'>\n";
            return parent::loginFormField($name, $heading, $value);
        }
        public function css()
        {
            return ['flesk-adminer.css?v=' . filemtime(__DIR__ . '/flesk-adminer.css') => 'light'];
        }
        public function verifyVersion()
        {
            return false;
        }
        public function headers()
        {
            header('X-Robots-Tag: noindex, nofollow');
        }
        public function csp(array $csp)
        {
            foreach ($csp as &$c) {
                foreach (['connect-src', 'frame-src'] as $k) {
                    if (isset($c[$k])) $c[$k] = trim(str_replace('https://www.adminer.org', '', $c[$k])) ?: "'self'";
                }
                $c['frame-ancestors'] = "'none'";
            }
            return $csp;
        }
    };
}

include dirname(__DIR__, 2) . '/vendor/adminer/adminer-6.1.1-mysql.php';
