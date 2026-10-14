<?php
/**
 * Flesk — contestador automático (Dovecot Pigeonhole, extensión "vacation") por buzón.
 * Lo invoca scripts/mail-vacation.sh como root:
 *   php mail-vacation.php get <email>          → JSON con la configuración
 *   php mail-vacation.php set <email>          ← JSON por stdin {enabled, subject, body, html, start, end}
 *   php mail-vacation.php off <email>
 *   php mail-vacation.php sync                 → regenera los scripts desde la BD (tras restaurar o reinstalar)
 * Guarda la configuración en la tabla mail_vacation y escribe ~/sieve/flesk-vacation.sieve (vmail, 0600), que se
 * valida con sievec y se activa enlazando ~/.dovecot.sieve. El home de Dovecot (~) es <maildir>/flesk: fuera de la
 * raíz del Maildir++, donde los nombres con punto (.dovecot.sieve, .dovecot.lda-dupes) serían carpetas IMAP. Responde como mucho una vez al día a cada remitente.
 */
declare(strict_types=1);

const VAC_SCRIPT = 'flesk-vacation';
const VAC_UID = 5000;
const VAC_GID = 5000;

function fail(int $code, string $msg): never { fwrite(STDERR, "ERROR: $msg\n"); exit($code); }

$root = getenv('FRESK_ROOT') ?: '/opt/flesk';
$cfg = [];
foreach (@file($root . '/config.conf', FILE_IGNORE_NEW_LINES) ?: [] as $l) {
    if (preg_match('/^\s*([A-Z0-9_]+)\s*=\s*"?([^"#]*)"?/', $l, $m)) $cfg[$m[1]] = trim($m[2]);
}
$pass = trim((string)@file_get_contents($root . '/var/.dbpass'));
if ($pass === '') fail(3, 'Falta la contraseña de la BD del panel');
try {
    $pdo = new PDO('mysql:host=' . ($cfg['DB_HOST'] ?? '127.0.0.1') . ';dbname=' . ($cfg['DB_NAME'] ?? 'fresk') . ';charset=utf8mb4',
        $cfg['DB_USER'] ?? 'fresk_panel', $pass, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
} catch (Throwable $e) { fail(3, 'No se pudo conectar a la BD'); }
$vmail = rtrim(getenv('VMAIL_HOME') ?: '/var/vmail', '/');
$tz = new DateTimeZone(($cfg['PANEL_TZ'] ?? '') !== '' ? $cfg['PANEL_TZ'] : 'Europe/Madrid');

/** Buzón → [id, email, home de Dovecot = <maildir>/flesk (se crea como vmail 0700)]. */
function mailbox(PDO $pdo, string $vmail, string $email): array {
    $email = strtolower(trim($email));
    if (!preg_match('/^([a-z0-9._+-]{1,64})@([a-z0-9.-]{1,253})$/', $email, $m)) fail(2, 'Email inválido');
    $st = $pdo->prepare('SELECT m.id, m.maildir FROM mailboxes m JOIN domains d ON d.id = m.domain_id WHERE d.name = ? AND m.local_part = ? LIMIT 1');
    $st->execute([$m[2], $m[1]]);
    $r = $st->fetch() ?: fail(3, 'Buzón no encontrado: ' . $email);
    $md = (string)$r['maildir'];
    $home = str_starts_with($md, '/') ? rtrim($md, '/') : $vmail . '/' . trim($md, '/');
    $real = realpath($home);
    if ($real === false || !str_starts_with($real . '/', $vmail . '/') || !is_dir($real)) fail(3, 'Carpeta del buzón no válida');
    $h = $real . '/flesk';
    if (is_link($h) || (file_exists($h) && !is_dir($h))) fail(3, 'Home Dovecot del buzón no válido');
    if (!is_dir($h)) { mkdir($h, 0700); chown($h, VAC_UID); chgrp($h, VAC_GID); }
    return [(int)$r['id'], $email, $h];
}

/** Cadena Sieve entre comillas (una línea). */
function sq(string $s): string {
    $s = preg_replace('/[\r\n\t]+/', ' ', $s) ?? '';
    return '"' . str_replace(['\\', '"'], ['\\\\', '\\"'], $s) . '"';
}
/** Cadena multilínea Sieve (text: … .), con "dot-stuffing". */
function ml(string $s): string {
    $s = str_replace(["\r\n", "\r"], "\n", $s);
    $lines = array_map(static fn($l) => str_starts_with($l, '.') ? '.' . $l : $l, explode("\n", $s));
    return "text:\n" . implode("\n", $lines) . "\n.\n";
}
/** Texto plano a partir de HTML (para la parte alternativa). */
function html_to_text(string $h): string {
    $h = preg_replace('#<(script|style)\b.*?</\1>#is', '', $h) ?? $h;
    $h = preg_replace('#<br\s*/?>|</(p|div|li|h[1-6]|tr)>#i', "\n", $h) ?? $h;
    $t = html_entity_decode(strip_tags($h), ENT_QUOTES | ENT_HTML5, 'UTF-8');
    return trim(preg_replace("/\n{3,}/", "\n\n", preg_replace('/[ \t]+/', ' ', $t) ?? $t) ?? $t);
}

function build_sieve(array $v, string $email, DateTimeZone $tz, array $addrs = []): string {
    $conds = [];
    $zone = (new DateTime($v['start_date'] ?? 'now', $tz))->format('O');
    if (!empty($v['start_date'])) $conds[] = 'currentdate :zone ' . sq($zone) . ' :value "ge" "date" ' . sq($v['start_date']);
    if (!empty($v['end_date'])) $conds[] = 'currentdate :zone ' . sq($zone) . ' :value "le" "date" ' . sq($v['end_date']);
    $body = (string)$v['body'];
    if ((int)$v['is_html'] === 1) {
        $b = 'flesk-' . bin2hex(random_bytes(8));
        $mime = "Content-Type: multipart/alternative; boundary=\"$b\"\n\n"
            . "--$b\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: 8bit\n\n" . html_to_text($body) . "\n"
            . "--$b\nContent-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: 8bit\n\n" . $body . "\n"
            . "--$b--";
        $reason = ':mime ' . ml($mime);
    } else {
        $reason = ml($body);
    }
    $vac = 'vacation :days 1 :subject ' . sq((string)$v['subject']) . ' :addresses [' . implode(', ', array_map('sq', array_values(array_unique(array_merge([$email], $addrs))))) . '] ' . $reason;
    $req = ['vacation'];
    if ($conds) { $req[] = 'date'; $req[] = 'relational'; }
    $out = "# Flesk: contestador automático de $email (generado por el panel; no editar a mano)\n"
        . 'require [' . implode(', ', array_map('sq', $req)) . "];\n";
    if ($conds) $out .= 'if allof(' . implode(', ', $conds) . ") {\n" . $vac . ";\n}\n";
    else $out .= $vac . ";\n"; // ml() termina en ".\n": el ";" va en su propia línea
    return $out;
}

/** Alias activos que entregan solo en este buzón: también cuentan como "mis direcciones" para vacation. */
function alias_addrs(string $email): array {
    global $pdo;
    $st = $pdo->prepare("SELECT LOWER(source) FROM aliases WHERE active = 1 AND LOWER(TRIM(destination)) = ? AND source LIKE '_%@_%'");
    $st->execute([strtolower($email)]);
    return array_values(array_filter($st->fetchAll(PDO::FETCH_COLUMN), static fn($a) => (bool)filter_var($a, FILTER_VALIDATE_EMAIL)));
}

/** Escribe, valida y (des)activa el script del buzón. */
function apply(array $v, string $email, string $home, DateTimeZone $tz): void {
    $dir = $home . '/sieve';
    $file = $dir . '/' . VAC_SCRIPT . '.sieve';
    $active = $home . '/.dovecot.sieve';
    $target = 'sieve/' . VAC_SCRIPT . '.sieve';
    $ours = is_link($active) && readlink($active) === $target;
    if (file_exists($active) || is_link($active)) {
        if (!$ours) fail(4, 'El buzón ya tiene otro filtro Sieve activo (~/.dovecot.sieve); no se sobrescribe');
    }
    if ((int)$v['enabled'] !== 1) {
        if ($ours) unlink($active);
        return;
    }
    if (!is_dir($dir)) { mkdir($dir, 0700); chown($dir, VAC_UID); chgrp($dir, VAC_GID); }
    $tmp = $dir . '/.' . VAC_SCRIPT . '.tmp.sieve';
    file_put_contents($tmp, build_sieve($v, $email, $tz, alias_addrs($email)), LOCK_EX);
    chmod($tmp, 0600); chown($tmp, VAC_UID); chgrp($tmp, VAC_GID);
    // Validación con el compilador de Pigeonhole. El binario va a un temporal propio que se borra:
    // NUNCA usar /dev/null como salida (sievec, como root, sustituye el destino por un fichero regular
    // y rompe /dev/null y el arranque de servicios con PrivateDevices).
    $bin = $dir . '/.' . VAC_SCRIPT . '.check.svbin';
    @unlink($bin);
    $p = proc_open(['sievec', $tmp, $bin], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pp);
    $o = stream_get_contents($pp[1]) . stream_get_contents($pp[2]); fclose($pp[1]); fclose($pp[2]);
    $rc = proc_close($p);
    @unlink($bin);
    if ($rc !== 0) { @unlink($tmp); fail(5, 'Script Sieve no válido: ' . trim(mb_substr($o, 0, 400))); }
    rename($tmp, $file);
    @unlink($dir . '/' . VAC_SCRIPT . '.svbin');
    if (!$ours) { symlink($target, $active); @lchown($active, VAC_UID); @lchgrp($active, VAC_GID); }
}

function load(PDO $pdo, int $id): array {
    $st = $pdo->prepare('SELECT enabled, subject, body, is_html, start_date, end_date, updated_at FROM mail_vacation WHERE mailbox_id = ?');
    $st->execute([$id]);
    return $st->fetch() ?: ['enabled' => 0, 'subject' => '', 'body' => '', 'is_html' => 0, 'start_date' => null, 'end_date' => null, 'updated_at' => null];
}

$action = $argv[1] ?? '';
switch ($action) {
    case 'get': {
        [$id, $email, $home] = mailbox($pdo, $vmail, (string)($argv[2] ?? ''));
        $v = load($pdo, $id);
        $active = is_link($home . '/.dovecot.sieve') && readlink($home . '/.dovecot.sieve') === 'sieve/' . VAC_SCRIPT . '.sieve';
        echo json_encode(['email' => $email, 'enabled' => (bool)$v['enabled'], 'active' => $active, 'subject' => $v['subject'], 'body' => $v['body'],
            'html' => (bool)$v['is_html'], 'start' => $v['start_date'], 'end' => $v['end_date'], 'updated_at' => $v['updated_at']], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "\n";
        exit(0);
    }
    case 'set': {
        [$id, $email, $home] = mailbox($pdo, $vmail, (string)($argv[2] ?? ''));
        $in = json_decode((string)stream_get_contents(STDIN), true);
        if (!is_array($in)) fail(2, 'Entrada JSON no válida');
        $en = !empty($in['enabled']) ? 1 : 0;
        $subject = trim((string)($in['subject'] ?? ''));
        $body = str_replace(["\r\n", "\r"], "\n", (string)($in['body'] ?? ''));
        $html = !empty($in['html']) ? 1 : 0;
        $start = trim((string)($in['start'] ?? '')) ?: null;
        $end = trim((string)($in['end'] ?? '')) ?: null;
        foreach (['start' => $start, 'end' => $end] as $k => $d) {
            if ($d !== null && (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $d) || !checkdate((int)substr($d, 5, 2), (int)substr($d, 8, 2), (int)substr($d, 0, 4)))) fail(2, "Fecha $k no válida (AAAA-MM-DD)");
        }
        if ($start !== null && $end !== null && $end < $start) fail(2, 'La fecha de fin es anterior a la de inicio');
        if (mb_strlen($subject) > 200 || preg_match('/[\x00-\x1f\x7f]/', $subject)) fail(2, 'Asunto no válido (máx. 200 caracteres, una línea)');
        if (strlen($body) > 64000 || str_contains($body, "\0") || !mb_check_encoding($body, 'UTF-8')) fail(2, 'Mensaje no válido (máx. 64 KB, UTF-8)');
        if ($en && ($subject === '' || trim($body) === '')) fail(2, 'Para activar el contestador indica asunto y mensaje');
        $v = ['enabled' => $en, 'subject' => $subject, 'body' => $body, 'is_html' => $html, 'start_date' => $start, 'end_date' => $end];
        apply($v, $email, $home, $tz);
        $pdo->prepare('INSERT INTO mail_vacation (mailbox_id, enabled, subject, body, is_html, start_date, end_date) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE enabled = VALUES(enabled), subject = VALUES(subject), body = VALUES(body), is_html = VALUES(is_html),
            start_date = VALUES(start_date), end_date = VALUES(end_date)')->execute([$id, $en, $subject, $body, $html, $start, $end]);
        echo 'OK mailbox=' . $email . ' vacation=' . ($en ? 'on' : 'off') . ' html=' . $html . ' start=' . ($start ?? '-') . ' end=' . ($end ?? '-') . "\n";
        exit(0);
    }
    case 'off': {
        [$id, $email, $home] = mailbox($pdo, $vmail, (string)($argv[2] ?? ''));
        $v = load($pdo, $id); $v['enabled'] = 0;
        apply($v, $email, $home, $tz);
        $pdo->prepare('UPDATE mail_vacation SET enabled = 0 WHERE mailbox_id = ?')->execute([$id]);
        echo "OK mailbox=$email vacation=off\n";
        exit(0);
    }
    case 'sync': {
        $rows = $pdo->query("SELECT CONCAT(m.local_part, '@', d.name) email, v.* FROM mail_vacation v JOIN mailboxes m ON m.id = v.mailbox_id JOIN domains d ON d.id = m.domain_id")->fetchAll();
        $n = 0;
        foreach ($rows as $r) { [, $email, $home] = mailbox($pdo, $vmail, $r['email']); apply($r, $email, $home, $tz); $n++; }
        echo "OK synced=$n\n";
        exit(0);
    }
    default:
        fail(2, 'Uso: flesk mail vacation get|set|off <email> | sync');
}
