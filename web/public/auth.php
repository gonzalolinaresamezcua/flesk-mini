<?php
/**
 * Flesk panel auth + CliClient (fase 8).
 * Sesión admin, CSRF, cliente CLI (sudo → bin/flesk) con whitelist.
 */
declare(strict_types=1);

session_name('fresk_panel');
// En CLI (pruebas) no hay sesión web: $_SESSION lo rellena el propio script
if (PHP_SAPI !== 'cli' && session_status() !== PHP_SESSION_ACTIVE) {
    $https = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
        || ((int)($_SERVER['SERVER_PORT'] ?? 0) === 443)
        || (strtolower((string)($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '')) === 'https');
    // Cookie solo bajo la ruta del panel (/flesk/): los sitios de clientes del mismo dominio no la reciben
    $fpath = '/flesk/';
    $fcfg = @file_get_contents('/opt/flesk/config.conf');
    if (is_string($fcfg) && preg_match('#^PANEL_BASE_PATH=(/[A-Za-z0-9._/-]*)\s*$#m', $fcfg, $fm)) {
        $fpath = rtrim($fm[1], '/') . '/';
    }
    unset($fcfg, $fm);
    session_start([
        'cookie_path'     => $fpath,
        'cookie_httponly' => true,
        'cookie_samesite' => 'Lax',
        'cookie_secure'   => $https, // solo Secure si HTTPS (panel por IP/HTTP no bloquea)
        'use_strict_mode' => true,
    ]);
}

require_once __DIR__ . '/includes/limits.php';

/** @return array<string,string> */
function fresk_cfg(): array {
    static $cfg = null;
    if ($cfg !== null) return $cfg;
    $cfg = [];
    $path = '/opt/flesk/config.conf';
    if (!is_readable($path)) {
        throw new RuntimeException('config.conf no legible');
    }
    foreach (file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#') continue;
        if (!str_contains($line, '=')) continue;
        [$k, $v] = explode('=', $line, 2);
        $cfg[trim($k)] = trim($v);
    }
    return $cfg;
}

function fresk_h(?string $s): string {
    return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8');
}

function fresk_base(): string {
    return rtrim((string)(fresk_cfg()['PANEL_BASE_PATH'] ?? '/flesk'), '/');
}

function fresk_pdo(): PDO {
    static $pdo = null;
    if ($pdo !== null) return $pdo;
    $cfg = fresk_cfg();
    $passFile = $cfg['DB_PASS_FILE'] ?? '/opt/flesk/var/.dbpass';
    $pass = trim((string)@file_get_contents($passFile));
    $dsn = sprintf(
        'mysql:host=%s;dbname=%s;charset=utf8mb4',
        $cfg['DB_HOST'] ?? '127.0.0.1',
        $cfg['DB_NAME'] ?? 'fresk'
    );
    $pdo = new PDO($dsn, $cfg['DB_USER'] ?? 'fresk_panel', $pass, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
    return $pdo;
}

function fresk_require_login(): void {
    if (!empty($_SESSION['fresk_admin_id'])) {
        return;
    }
    header('Location: ' . fresk_base() . '/login.php');
    exit;
}

const FRESK_LOGIN_MAX_FAILS = 5;
const FRESK_LOGIN_LOCK_MINUTES = 15;

function fresk_login(string $user, string $pass): bool {
    $stmt = fresk_pdo()->prepare(
        'SELECT id, username, password_hash, active, locked_until, failed_logins
         FROM admins WHERE username = ? LIMIT 1'
    );
    $stmt->execute([$user]);
    $row = $stmt->fetch();
    if (!$row || !(int)$row['active']) {
        return false;
    }
    if (!empty($row['locked_until']) && strtotime((string)$row['locked_until']) > time()) {
        return false;
    }
    if (!password_verify($pass, $row['password_hash'])) {
        $fails = (int)$row['failed_logins'] + 1;
        if ($fails >= FRESK_LOGIN_MAX_FAILS) {
            $until = date('Y-m-d H:i:s', time() + FRESK_LOGIN_LOCK_MINUTES * 60);
            fresk_pdo()->prepare(
                'UPDATE admins SET failed_logins = ?, locked_until = ? WHERE id = ?'
            )->execute([$fails, $until, (int)$row['id']]);
        } else {
            fresk_pdo()->prepare('UPDATE admins SET failed_logins = ? WHERE id = ?')
                ->execute([$fails, (int)$row['id']]);
        }
        // También contador de sesión (defensa en profundidad si DB falla parcialmente)
        $_SESSION['fresk_login_fails'] = (int)($_SESSION['fresk_login_fails'] ?? 0) + 1;
        return false;
    }
    fresk_pdo()->prepare('UPDATE admins SET failed_logins = 0, locked_until = NULL WHERE id = ?')
        ->execute([(int)$row['id']]);
    // Último acceso + idioma preferido (columnas añadidas en migración 1.0.0-rc2)
    $prefLang = '';
    try {
        fresk_pdo()->prepare('UPDATE admins SET last_login_at = NOW() WHERE id = ?')
            ->execute([(int)$row['id']]);
        $ls = fresk_pdo()->prepare('SELECT language FROM admins WHERE id = ?');
        $ls->execute([(int)$row['id']]);
        $prefLang = (string)($ls->fetchColumn() ?: '');
    } catch (Throwable $e) {
        $prefLang = '';
    }
    unset($_SESSION['fresk_login_fails']);
    session_regenerate_id(true);
    $_SESSION['fresk_admin_id'] = (int)$row['id'];
    $_SESSION['fresk_admin_user'] = $row['username'];
    if ($prefLang !== '' && function_exists('fresk_set_session_lang')) {
        fresk_set_session_lang($prefLang);
    }
    return true;
}

/** True si el usuario está bloqueado (DB o sesión). */
function fresk_login_is_locked(string $user = ''): bool {
    if ((int)($_SESSION['fresk_login_fails'] ?? 0) >= FRESK_LOGIN_MAX_FAILS) {
        return true;
    }
    if ($user === '') return false;
    try {
        $stmt = fresk_pdo()->prepare(
            'SELECT locked_until, failed_logins FROM admins WHERE username = ? LIMIT 1'
        );
        $stmt->execute([$user]);
        $row = $stmt->fetch();
        if (!$row) return false;
        if ((int)$row['failed_logins'] >= FRESK_LOGIN_MAX_FAILS
            && !empty($row['locked_until'])
            && strtotime((string)$row['locked_until']) > time()) {
            return true;
        }
    } catch (Throwable $e) {
        return false;
    }
    return false;
}

function fresk_logout(): void {
    $_SESSION = [];
    if (ini_get('session.use_cookies')) {
        $p = session_get_cookie_params();
        setcookie(session_name(), '', time() - 42000, $p['path'], $p['domain'], (bool)$p['secure'], (bool)$p['httponly']);
    }
    session_destroy();
}

function fresk_csrf_token(): string {
    if (empty($_SESSION['fresk_csrf'])) {
        $_SESSION['fresk_csrf'] = bin2hex(random_bytes(16));
    }
    return (string)$_SESSION['fresk_csrf'];
}

function fresk_csrf_check(): void {
    $t = (string)($_POST['csrf'] ?? '');
    if ($t === '' || empty($_SESSION['fresk_csrf']) || !hash_equals((string)$_SESSION['fresk_csrf'], $t)) {
        http_response_code(403);
        echo 'CSRF inválido';
        exit;
    }
}

/** Valida dominio en PHP (rechaza ; y espacios antes de sudo). */
function fresk_valid_domain(string $d): ?string {
    $d = strtolower(rtrim(trim($d), '.'));
    if ($d === '' || strlen($d) > 253) return null;
    if (str_contains($d, ';') || preg_match('/\s/', $d)) return null;
    if (str_contains($d, '://') || str_contains($d, '/')) return null;
    if (!preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/', $d)
        && !preg_match('/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/', $d)) {
        return null;
    }
    return $d;
}

/**
 * Subcomandos registrados (CliClient whitelist).
 * Clave: "grupo/sub" → true.
 * @return array<string,true>
 */
function fresk_cli_whitelist(): array {
    static $w = null;
    if ($w !== null) return $w;
    $w = [];
    $map = [
        'status'  => [''],
        'domain'  => ['add', 'del', 'remove', 'rm', 'list', 'ls'],
        'mail'    => ['add', 'passwd', 'del', 'remove', 'rm', 'list', 'ls', 'vacation'],
        'alias'   => ['add', 'del', 'remove', 'rm'],
        'forward' => ['add', 'del', 'remove', 'rm'],
        'dns'     => ['set', 'del', 'remove', 'rm', 'init', 'list', 'ls'],
        'ssl'     => ['obtain', 'issue', 'renew', 'renew-all', 'status'],
        'db'      => ['add', 'create', 'del', 'drop', 'remove', 'rm', 'list', 'ls', 'passwd', 'dump', 'login', 'logout', 'appinfo'],
        'sftp'    => ['add', 'del', 'remove', 'rm', 'list', 'ls', 'passwd'],
        'files'   => ['fixperms', 'backup', 'empty'],
        'webmail' => ['vhost', 'ssl'],
    ];
    foreach ($map as $group => $subs) {
        foreach ($subs as $sub) {
            $w[$group . '/' . $sub] = true;
        }
    }
    return $w;
}

/**
 * CliClient: solo subcomandos registrados; argv como array; timeout 60s.
 * Captura código de salida y línea PASSWORD=.
 * @param list<string> $args  p.ej. ['domain','add','ejemplo.com']
 * @param ?string $stdin     datos opcionales para stdin (p.ej. contraseña con --password-stdin)
 * @return array{code:int,stdout:string,stderr:string,password:?string}
 */
function fresk_cli(array $args, ?string $stdin = null, float $timeout = 60.0): array {
    if ($args === []) {
        return ['code' => 2, 'stdout' => '', 'stderr' => 'Sin argumentos', 'password' => null];
    }
    foreach ($args as $a) {
        if (!is_string($a) || str_contains($a, "\0")) {
            return ['code' => 2, 'stdout' => '', 'stderr' => 'Argumento inválido', 'password' => null];
        }
    }
    $group = $args[0];
    $sub = $args[1] ?? '';
    $key = $group . '/' . $sub;
    if (!isset(fresk_cli_whitelist()[$key])) {
        return ['code' => 2, 'stdout' => '', 'stderr' => 'Comando no permitido: ' . $group . ' ' . $sub, 'password' => null];
    }
    // Rechazo temprano de dominio con ; o espacio en posiciones típicas
    foreach ($args as $a) {
        if (str_contains($a, ';') || (str_contains($a, ' ') && !preg_match('/^(10|20|30)\s/', $a) && !str_starts_with($a, 'v='))) {
            // MX "10 mail.x" y TXT spf pueden tener espacios; validación fina en páginas
            if (preg_match('/[;`$|&<>]/', $a) || str_contains($a, "\n")) {
                return ['code' => 2, 'stdout' => '', 'stderr' => 'Caracteres no permitidos en argumento', 'password' => null];
            }
        }
        if (str_contains($a, ';')) {
            return ['code' => 2, 'stdout' => '', 'stderr' => 'Caracteres no permitidos en argumento', 'password' => null];
        }
    }

    // Flesk Mini: límite de 1 recurso comprobado aquí (antes de llamar al motor) y de nuevo en el motor (lib/limits.sh)
    $mini = fresk_mini_precheck($group, $sub);
    if ($mini !== null) {
        return ['code' => 7, 'stdout' => '', 'stderr' => $mini, 'password' => null, 'mini_limit' => true];
    }

    $bin = '/opt/flesk/bin/flesk';
    $cmd = array_merge(['sudo', '-n', $bin], $args);
    $descriptors = [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ];
    $proc = proc_open($cmd, $descriptors, $pipes, null, null, ['bypass_shell' => true]);
    if (!is_resource($proc)) {
        return ['code' => 5, 'stdout' => '', 'stderr' => 'No se pudo lanzar flesk', 'password' => null];
    }
    if ($stdin !== null) {
        fwrite($pipes[0], $stdin . "\n");
    }
    fclose($pipes[0]);
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);
    $stdout = '';
    $stderr = '';
    $deadline = microtime(true) + max(5.0, min(900.0, $timeout));
    while (true) {
        $status = proc_get_status($proc);
        $stdout .= stream_get_contents($pipes[1]) ?: '';
        $stderr .= stream_get_contents($pipes[2]) ?: '';
        if (!$status['running']) {
            break;
        }
        if (microtime(true) >= $deadline) {
            proc_terminate($proc, 9);
            fclose($pipes[1]);
            fclose($pipes[2]);
            proc_close($proc);
            return ['code' => 5, 'stdout' => $stdout, 'stderr' => 'Timeout ' . (int)$timeout . 's', 'password' => null];
        }
        usleep(50000);
    }
    // drenar resto
    $stdout .= stream_get_contents($pipes[1]) ?: '';
    $stderr .= stream_get_contents($pipes[2]) ?: '';
    fclose($pipes[1]);
    fclose($pipes[2]);
    $code = proc_close($proc);
    $password = null;
    if (preg_match('/^PASSWORD=(.+)$/m', $stdout, $m)) {
        $password = $m[1];
    }
    $res = ['code' => (int)$code, 'stdout' => $stdout, 'stderr' => $stderr, 'password' => $password];
    if ((int)$code === 7 && str_contains($stderr, 'FLESK_MINI_LIMIT')) {
        $res['stderr'] = fresk_mini_limit_message();
        $res['mini_limit'] = true;
    }
    return $res;
}

/** Valida email local@dominio. */
function fresk_valid_email(string $e): ?string {
    $e = strtolower(trim($e));
    if ($e === '' || !str_contains($e, '@')) return null;
    if (str_contains($e, ';') || preg_match('/\s/', $e)) return null;
    [$local, $domain] = explode('@', $e, 2);
    if (!preg_match('/^[a-z0-9]([a-z0-9._-]{0,63})$/', $local)) return null;
    $domain = fresk_valid_domain($domain);
    if ($domain === null) return null;
    return $local . '@' . $domain;
}

/** Destino de alias/forward (un email). */
function fresk_valid_destination(string $d): ?string {
    $d = strtolower(trim($d));
    if ($d === '' || strlen($d) > 255) return null;
    if (preg_match('/[;{}$`|&<>]/', $d)) return null;
    return fresk_valid_email($d);
}

/** Extrae PASSWORD=... de stdout de flesk (compat). */
function fresk_extract_password(string $stdout): ?string {
    if (preg_match('/^PASSWORD=(.+)$/m', $stdout, $m)) {
        return $m[1];
    }
    return null;
}

/* ---------- Usuarios admin: política de contraseñas y auditoría ---------- */

const FRESK_USERNAME_RE = '/^[a-z][a-z0-9_.-]{2,31}$/';

function fresk_valid_username(string $u): bool {
    return (bool)preg_match(FRESK_USERNAME_RE, $u);
}

/**
 * Política de contraseña (servidor): mínimo 8, máx 128, al menos
 * una mayúscula, una minúscula, un número y un símbolo.
 * @return list<string> claves i18n de requisitos incumplidos (vacío = OK)
 */
function fresk_password_problems(string $p): array {
    $e = [];
    $len = mb_strlen($p, 'UTF-8');
    if ($len < 8) $e[] = 'pw.len';
    if ($len > 128) $e[] = 'pw.max';
    if (!preg_match('/\p{Lu}/u', $p)) $e[] = 'pw.upper';
    if (!preg_match('/\p{Ll}/u', $p)) $e[] = 'pw.lower';
    if (!preg_match('/\p{Nd}/u', $p)) $e[] = 'pw.digit';
    if (!preg_match('/[^\p{L}\p{N}\s]/u', $p)) $e[] = 'pw.symbol';
    return $e;
}

/** Registra en audit_log (nunca contraseñas). */
function fresk_audit(string $action, ?string $target, string $result, ?string $detail = null): void {
    try {
        fresk_pdo()->prepare(
            'INSERT INTO audit_log (actor, action, target, result, detail) VALUES (?, ?, ?, ?, ?)'
        )->execute([
            'panel:' . (string)($_SESSION['fresk_admin_user'] ?? '?'),
            $action,
            $target,
            $result,
            $detail,
        ]);
    } catch (Throwable $e) {
        error_log('flesk audit: ' . $e->getMessage());
    }
}

/* ---------- SGBD: registro de bases, SSO de Adminer y volcados ---------- */

const FLESK_SGBD_TOKEN_TTL = 60;

/** True si la base está registrada en el panel (tabla databases). */
function fresk_db_registered(string $db): bool {
    if (!preg_match('/^db_[a-z0-9_]{1,61}$/', $db)) return false;
    $st = fresk_pdo()->prepare('SELECT 1 FROM `databases` WHERE db_name = ? LIMIT 1');
    $st->execute([$db]);
    return (bool)$st->fetchColumn();
}

/**
 * Token de un solo uso (60 s) para abrir Adminer ya autenticado en $db.
 * Solo se guarda su hash en la sesión del panel: ligado a esa sesión, a ese admin y a esa base.
 */
function fresk_sgbd_issue_token(string $db): string {
    $now = time();
    $list = is_array($_SESSION['flesk_sgbd_sso'] ?? null) ? $_SESSION['flesk_sgbd_sso'] : [];
    $list = array_filter($list, static fn($e) => is_array($e) && (int)($e['exp'] ?? 0) > $now);
    $list = array_slice($list, -9, null, true);
    $tok = bin2hex(random_bytes(32));
    $list[hash('sha256', $tok)] = ['db' => $db, 'exp' => $now + FLESK_SGBD_TOKEN_TTL, 'admin' => (int)($_SESSION['fresk_admin_id'] ?? 0)];
    $_SESSION['flesk_sgbd_sso'] = $list;
    return $tok;
}

/** Consume el token (siempre lo invalida). Devuelve la base o null si no vale / caducó / es de otro admin. */
function fresk_sgbd_consume_token(string $tok): ?string {
    if (!preg_match('/^[a-f0-9]{64}$/', $tok)) return null;
    $h = hash('sha256', $tok);
    $list = is_array($_SESSION['flesk_sgbd_sso'] ?? null) ? $_SESSION['flesk_sgbd_sso'] : [];
    $e = $list[$h] ?? null;
    unset($list[$h]);
    $_SESSION['flesk_sgbd_sso'] = $list;
    if (!is_array($e) || (int)($e['exp'] ?? 0) < time()) return null;
    if ((int)($e['admin'] ?? -1) !== (int)($_SESSION['fresk_admin_id'] ?? -2)) return null;
    return (string)$e['db'];
}

/** Borra las credenciales efímeras de Adminer creadas en esta sesión del panel (logout). */
function fresk_sgbd_drop_session_users(): void {
    $users = is_array($_SESSION['flesk_sgbd_eph'] ?? null) ? array_keys($_SESSION['flesk_sgbd_eph']) : [];
    foreach ($users as $u) {
        if (preg_match('/^fks_[0-9]{10}_[a-f0-9]{10}$/', (string)$u)) fresk_cli(['db', 'logout', (string)$u]);
    }
    unset($_SESSION['flesk_sgbd_eph']);
}

/**
 * Descarga en streaming de `flesk db dump <db>` (gzip) sin ficheros temporales.
 * Si el volcado no arranca devuelve el error (sin enviar cabeceras); si arranca, termina con exit.
 */
function fresk_db_stream_dump(string $db): string {
    if (!isset(fresk_cli_whitelist()['db/dump']) || !fresk_db_registered($db)) return 'Base no registrada';
    $proc = proc_open(['sudo', '-n', '/opt/flesk/bin/flesk', 'db', 'dump', $db],
        [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, null, ['bypass_shell' => true]);
    if (!is_resource($proc)) return 'No se pudo lanzar flesk';
    fclose($pipes[0]);
    stream_set_blocking($pipes[2], false);
    $stderr = '';
    $first = '';
    while (!feof($pipes[1]) && $first === '') {
        $r = [$pipes[1], $pipes[2]]; $w = null; $x = null;
        if (stream_select($r, $w, $x, 30) === false) break;
        foreach ($r as $p) {
            if ($p === $pipes[2]) $stderr .= (string)stream_get_contents($pipes[2]);
            else $first .= (string)fread($pipes[1], 65536);
        }
    }
    if ($first === '') {
        stream_set_blocking($pipes[2], true);
        $stderr .= (string)stream_get_contents($pipes[2]);
        fclose($pipes[1]); fclose($pipes[2]);
        $code = proc_close($proc);
        fresk_audit('db.dump', $db, 'fail', 'rc=' . $code);
        return 'Error al volcar (' . $code . '): ' . trim(preg_replace('/^\S+ \S+ \S+ \[\w+\] /m', '', $stderr));
    }
    @set_time_limit(0);
    session_write_close();
    while (ob_get_level() > 0) ob_end_clean();
    $fname = $db . '-' . date('Ymd-His') . '.sql.gz';
    header('Content-Type: application/gzip');
    header('Content-Disposition: attachment; filename="' . $fname . '"');
    header('Cache-Control: no-store, private');
    header('X-Content-Type-Options: nosniff');
    header('X-Accel-Buffering: no');
    echo $first;
    flush();
    $bytes = strlen($first);
    $aborted = false;
    while (!feof($pipes[1])) {
        $c = fread($pipes[1], 65536);
        if ($c === false) break;
        if ($c !== '') { echo $c; flush(); $bytes += strlen($c); }
        $stderr .= (string)stream_get_contents($pipes[2]);
        if (connection_aborted()) { $aborted = true; proc_terminate($proc); break; }
    }
    fclose($pipes[1]);
    fclose($pipes[2]);
    $code = proc_close($proc);
    fresk_audit('db.dump', $db, ($code === 0 && !$aborted) ? 'ok' : 'fail',
        'bytes=' . $bytes . ($aborted ? ' abortada' : '') . ($code !== 0 ? ' rc=' . $code : ''));
    exit;
}

/** " db=<base>" a partir de la salida de una instalación (registro exacto de qué base usa cada app). */
function fresk_audit_db_suffix(string $out): string {
    return preg_match('/\bDB=(db_[a-z0-9_]{1,61})\b/', $out, $m) ? ' db=' . $m[1] : '';
}

/**
 * Refresca la caché db_app_cache con `flesk db appinfo` (lectura de configs de apps, registro e inspección de la base).
 * @return bool true si se pudo detectar
 */
function fresk_db_apps_refresh(): bool {
    $r = fresk_cli(['db', 'appinfo'], null, 120.0);
    $list = $r['code'] === 0 ? json_decode(trim($r['stdout']), true) : null;
    if (!is_array($list)) return false;
    $pdo = fresk_pdo();
    $up = $pdo->prepare('REPLACE INTO db_app_cache (db_name, app, app_name, version, path, url, source, tables_count, note, detected_at)
                         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())');
    $keep = [];
    foreach ($list as $e) {
        if (!is_array($e) || !preg_match('/^db_[a-z0-9_]{1,61}$/', (string)($e['db'] ?? ''))) continue;
        $s = static fn($k, $n) => isset($e[$k]) && $e[$k] !== null ? mb_substr((string)$e[$k], 0, $n) : null;
        $url = $s('url', 255);
        if ($url !== null && !preg_match('#^https?://[^\s"<>]+$#', $url)) $url = null;
        $up->execute([$e['db'], $s('app', 32), $s('name', 64), $s('version', 32), $s('path', 255), $url, $s('source', 64), (int)($e['tables'] ?? 0), $s('note', 32)]);
        $keep[] = $e['db'];
    }
    if ($keep) {
        $in = implode(',', array_fill(0, count($keep), '?'));
        $pdo->prepare("DELETE FROM db_app_cache WHERE db_name NOT IN ($in)")->execute($keep);
    } else {
        $pdo->exec('DELETE FROM db_app_cache');
    }
    return true;
}

require_once __DIR__ . '/includes/i18n.php';
