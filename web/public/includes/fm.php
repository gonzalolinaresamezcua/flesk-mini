<?php
/**
 * Flesk: librería del gestor de archivos (jaula realpath, ZIP). Usada por files.php y por el agente IA.
 */
declare(strict_types=1);

const FM_EDIT_MAX = 2 * 1024 * 1024;       // 2 MB editables
const FM_UPLOAD_MAX = 64 * 1024 * 1024;    // 64 MB por archivo (también limitado por PHP/nginx)
const FM_LIST_MAX = 5000;

function fm_vhosts_root(): string {
    return rtrim((string)(fresk_cfg()['VHOSTS_ROOT'] ?? '/var/www/vhosts'), '/');
}

/** @return list<string> dominios registrados */
function fm_domains(): array {
    return array_map('strval', fresk_pdo()->query('SELECT name FROM domains ORDER BY name')->fetchAll(PDO::FETCH_COLUMN));
}

final class FmError extends RuntimeException {}

/** Normaliza ruta relativa: sin NUL, sin '..', sin segmentos vacíos. */
function fm_norm(string $rel): string {
    if (str_contains($rel, "\0") || preg_match('/[\x00-\x1f\x7f]/', $rel)) throw new FmError(t('fm.err_path'));
    $rel = str_replace('\\', '/', $rel);
    $parts = [];
    foreach (explode('/', $rel) as $seg) {
        if ($seg === '' || $seg === '.') continue;
        if ($seg === '..') throw new FmError(t('fm.err_path'));
        $parts[] = $seg;
    }
    return implode('/', $parts);
}

function fm_valid_name(string $n): bool {
    if ($n === '' || $n === '.' || $n === '..' || strlen($n) > 255) return false;
    if (!mb_check_encoding($n, 'UTF-8')) return false;
    return !preg_match('/[\/\\\\\x00-\x1f\x7f;`$|&<>"*?:]/', $n);
}

/** Raíz real del dominio (jaula). */
function fm_root(string $domain): string {
    $r = realpath(fm_vhosts_root() . '/' . $domain);
    if ($r === false || !is_dir($r)) throw new FmError(t('fm.err_notfound'));
    return $r;
}

function fm_inside(string $real, string $root): bool {
    return $real === $root || str_starts_with($real, $root . '/');
}

/** Resuelve ruta existente dentro de la jaula (sigue symlinks y comprueba destino). */
function fm_resolve(string $root, string $rel): string {
    $rel = fm_norm($rel);
    $p = $rel === '' ? $root : $root . '/' . $rel;
    $real = realpath($p);
    if ($real === false) throw new FmError(t('fm.err_notfound'));
    if (!fm_inside($real, $root)) throw new FmError(t('fm.err_path'));
    return $real;
}

/** Zona escribible: httpdocs real. */
function fm_write_zone(string $root): string {
    $h = realpath($root . '/httpdocs');
    if ($h === false) throw new FmError(t('fm.err_write_zone'));
    return $h;
}

function fm_assert_writable_zone(string $real, string $root): void {
    $zone = fm_write_zone($root);
    if (!str_starts_with($real, $zone . '/')) throw new FmError(t('fm.err_write_zone'));
}

/** Ruta relativa a httpdocs (para el helper root). */
function fm_rel_httpdocs(string $real, string $root): string {
    return substr($real, strlen(fm_write_zone($root)) + 1);
}

/** Ajusta dueño/permisos vía helper root (flesk files fixperms). */
function fm_fixperms(string $domain, string $real, string $root): bool {
    $rel = fm_rel_httpdocs($real, $root);
    if ($rel === '' || $rel === false) return false;
    $r = fresk_cli(['files', 'fixperms', $domain, $rel]);
    return $r['code'] === 0;
}

function fm_rel(string $real, string $root): string {
    return $real === $root ? '' : substr($real, strlen($root) + 1);
}

function fm_ext(string $name): string {
    return strtolower(pathinfo($name, PATHINFO_EXTENSION));
}

/** Tipo de visor para el cliente. */
function fm_kind(string $name): string {
    $e = fm_ext($name);
    return match (true) {
        in_array($e, ['png', 'jpg', 'jpeg', 'gif', 'webp', 'ico', 'bmp', 'avif', 'svg'], true) => 'image',
        in_array($e, ['mp3', 'ogg', 'oga', 'wav', 'm4a', 'flac', 'aac', 'opus'], true) => 'audio',
        in_array($e, ['mp4', 'webm', 'ogv', 'mov', 'm4v'], true) => 'video',
        $e === 'pdf' => 'pdf',
        $e === 'docx' => 'docx',
        in_array($e, ['xlsx', 'xls', 'ods'], true) => 'sheet',
        $e === 'csv' => 'csv',
        in_array($e, ['zip', 'gz', 'tgz', 'tar', 'rar', '7z', 'bz2', 'xz', 'exe', 'bin', 'so', 'woff', 'woff2', 'ttf', 'otf', 'eot', 'doc', 'ppt', 'pptx', 'sqlite', 'db'], true) => 'binary',
        default => 'text',
    };
}

/** MIME seguro para servir inline (nunca text/html ni ejecutable). */
function fm_safe_mime(string $name): array {
    $e = fm_ext($name);
    $map = [
        'png' => 'image/png', 'jpg' => 'image/jpeg', 'jpeg' => 'image/jpeg', 'gif' => 'image/gif',
        'webp' => 'image/webp', 'ico' => 'image/x-icon', 'bmp' => 'image/bmp', 'avif' => 'image/avif',
        'svg' => 'image/svg+xml',
        'mp3' => 'audio/mpeg', 'ogg' => 'audio/ogg', 'oga' => 'audio/ogg', 'wav' => 'audio/wav', 'm4a' => 'audio/mp4',
        'flac' => 'audio/flac', 'aac' => 'audio/aac', 'opus' => 'audio/ogg',
        'mp4' => 'video/mp4', 'webm' => 'video/webm', 'ogv' => 'video/ogg', 'mov' => 'video/quicktime', 'm4v' => 'video/mp4',
        'pdf' => 'application/pdf',
    ];
    if (isset($map[$e])) return [$map[$e], true];
    return ['application/octet-stream', false];
}

function fm_json(array $data, int $code = 200): never {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    header('X-Content-Type-Options: nosniff');
    header('Cache-Control: no-store');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

function fm_entry(string $real, string $root): array {
    $name = basename($real);
    $isLink = is_link($real);
    $isDir = is_dir($real);
    $st = @lstat($real) ?: [];
    return [
        'name' => $name,
        'path' => fm_rel($real, $root),
        'type' => $isDir ? 'dir' : 'file',
        'link' => $isLink,
        'size' => $isDir ? null : (int)($st['size'] ?? 0),
        'mtime' => isset($st['mtime']) ? date('Y-m-d H:i', (int)$st['mtime']) : '',
        'kind' => $isDir ? 'dir' : fm_kind($name),
        'writable' => false,
    ];
}

function fm_rmtree(string $dir): void {
    $it = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::CHILD_FIRST
    );
    foreach ($it as $f) {
        /** @var SplFileInfo $f */
        $p = $f->getPathname();
        if (is_link($p) || !$f->isDir()) {
            if (!@unlink($p)) throw new FmError(t('fm.err_perm'));
        } else {
            if (!@rmdir($p)) throw new FmError(t('fm.err_perm'));
        }
    }
    if (!@rmdir($dir)) throw new FmError(t('fm.err_perm'));
}

function fm_human_bytes(int $b): string {
    $u = ['B', 'KB', 'MB', 'GB'];
    $i = 0;
    $v = (float)$b;
    while ($v >= 1024 && $i < 3) { $v /= 1024; $i++; }
    return ($i ? number_format($v, 1) : (string)$b) . ' ' . $u[$i];
}

function fm_ini_bytes(string $v): int {
    $v = trim($v);
    $n = (int)$v;
    return match (strtolower(substr($v, -1))) { 'g' => $n << 30, 'm' => $n << 20, 'k' => $n << 10, default => $n };
}

function fm_upload_limit(): int {
    return max(1, min(FM_UPLOAD_MAX, fm_ini_bytes((string)ini_get('upload_max_filesize')), fm_ini_bytes((string)ini_get('post_max_size'))));
}

/** Límites de la descarga ZIP (config.conf: FILES_ZIP_MAX_MB, FILES_ZIP_MAX_FILES). */
function fm_zip_limits(): array {
    $c = fresk_cfg();
    $mb = (int)($c['FILES_ZIP_MAX_MB'] ?? 1024);
    $n = (int)($c['FILES_ZIP_MAX_FILES'] ?? 20000);
    return [max(1, $mb) * 1024 * 1024, max(1, $n)];
}

/**
 * Recorre una carpeta sin seguir symlinks que salgan de la jaula (los symlinks a carpetas
 * no se recorren para evitar bucles). Devuelve [entradas, bytes]; entrada = [real|null, nombre_en_zip].
 */
function fm_zip_collect(string $dir, string $root, string $prefix): array {
    [$maxBytes, $maxFiles] = fm_zip_limits();
    $out = [[null, $prefix . '/']];
    $bytes = 0; $files = 0;
    $stack = [[$dir, $prefix]];
    while ($stack) {
        [$d, $arc] = array_pop($stack);
        $names = @scandir($d);
        if ($names === false) continue;
        foreach ($names as $n) {
            if ($n === '.' || $n === '..') continue;
            $full = $d . '/' . $n;
            $an = $arc . '/' . $n;
            if (is_link($full)) {
                $t = realpath($full);
                if ($t === false || !fm_inside($t, $root) || is_dir($t)) continue;
                $full = $t;
            } elseif (is_dir($full)) {
                $out[] = [null, $an . '/'];
                $stack[] = [$full, $an];
                continue;
            }
            if (!is_file($full) || !is_readable($full)) continue;
            $files++;
            $bytes += (int)@filesize($full);
            if ($files > $maxFiles) throw new FmError(t('fm.zip_too_many', $maxFiles));
            if ($bytes > $maxBytes) throw new FmError(t('fm.zip_too_big', fm_human_bytes($maxBytes)));
            $out[] = [$full, $an];
        }
    }
    return [$out, $bytes, $files];
}

/** Lista de rutas (paths[]) del POST: normalizadas, únicas, máx. 500. */
function fm_post_paths(): array {
    $raw = $_POST['paths'] ?? null;
    if (!is_array($raw) || $raw === []) throw new FmError(t('fm.err_none_selected'));
    if (count($raw) > 500) throw new FmError(t('fm.err_too_many_selected', 500));
    $out = []; $bad = [];
    foreach ($raw as $p) {
        if (!is_string($p)) throw new FmError(t('fm.err_path'));
        try { $out[fm_norm($p)] = true; }
        catch (FmError $e) { $bad[] = ['path' => mb_substr(preg_replace('/[\x00-\x1f\x7f]/', '?', $p) ?? '', 0, 255), 'error' => $e->getMessage()]; }
    }
    // Todo o nada: si alguna ruta no es válida, informar por elemento y no hacer nada
    if ($bad) fm_json(['ok' => false, 'error' => t('fm.err_some_invalid'), 'items' => $bad], 400);
    return array_keys($out);
}

/** Quita rutas cuyo antecesor también está seleccionado (evita duplicados en ZIP/borrado). */
function fm_prune_nested(array $rels): array {
    sort($rels, SORT_STRING);
    $keep = [];
    foreach ($rels as $r) {
        $nested = false;
        foreach ($keep as $k) { if ($k === '' || str_starts_with($r, $k . '/')) { $nested = true; break; } }
        if (!$nested) $keep[] = $r;
    }
    return $keep;
}

/** Directorio común (relativo) de varias rutas. */
function fm_common_parent(array $rels): string {
    $parts = null;
    foreach ($rels as $r) {
        $segs = explode('/', $r); array_pop($segs);
        if ($parts === null) { $parts = $segs; continue; }
        $i = 0; while ($i < count($parts) && $i < count($segs) && $parts[$i] === $segs[$i]) $i++;
        $parts = array_slice($parts, 0, $i);
    }
    return implode('/', $parts ?? []);
}

/** Envía un ZIP ya construido y lo borra. */
function fm_zip_send(string $tmp, string $zname): never {
    clearstatcache(true, $tmp);
    ignore_user_abort(true);
    while (ob_get_level() > 0) ob_end_clean();
    $ascii = preg_replace('/[^A-Za-z0-9._-]/', '_', $zname);
    header('Content-Type: application/zip');
    header('X-Content-Type-Options: nosniff');
    header('Cache-Control: private, no-store');
    header('Content-Length: ' . (string)filesize($tmp));
    header("Content-Disposition: attachment; filename=\"{$ascii}\"; filename*=UTF-8''" . rawurlencode($zname));
    readfile($tmp);
    @unlink($tmp);
    exit;
}

/** Construye el ZIP en un temporal privado a partir de entradas [real|null, arc]. */
function fm_zip_build(array $entries): string {
    $tmp = tempnam(fm_zip_tmpdir(), 'fz');
    if ($tmp === false) throw new FmError(t('fm.err_generic'));
    @chmod($tmp, 0600);
    register_shutdown_function(static function () use ($tmp) { if (is_file($tmp)) @unlink($tmp); });
    $zip = new ZipArchive();
    if ($zip->open($tmp, ZipArchive::OVERWRITE) !== true) throw new FmError(t('fm.err_generic'));
    foreach ($entries as [$src, $arc]) {
        if ($src === null) { $zip->addEmptyDir(rtrim($arc, '/')); continue; }
        if (!$zip->addFile($src, $arc)) { $zip->close(); throw new FmError(t('fm.err_generic')); }
        if (preg_match('/\.(zip|gz|tgz|bz2|xz|7z|rar|jpe?g|png|gif|webp|avif|mp[34]|webm|ogg|woff2?)$/i', $arc)) {
            $zip->setCompressionName($arc, ZipArchive::CM_STORE);
        }
    }
    if (!$zip->close()) throw new FmError(t('fm.err_generic'));
    return $tmp;
}

/** Directorio temporal privado (0700) para los ZIP; limpia restos de más de 1 h. */
function fm_zip_tmpdir(): string {
    $d = rtrim(sys_get_temp_dir(), '/') . '/flesk-zip';
    if (!is_dir($d) && !@mkdir($d, 0700, true) && !is_dir($d)) throw new FmError(t('fm.err_generic'));
    @chmod($d, 0700);
    foreach (glob($d . '/fz*') ?: [] as $old) {
        if (is_file($old) && filemtime($old) < time() - 3600) @unlink($old);
    }
    return $d;
}

