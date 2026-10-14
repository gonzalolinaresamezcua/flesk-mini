<?php
/**
 * Flesk: gestor de archivos (estilo editor + nube) por dominio.
 * Seguridad: login admin, CSRF en todo POST, jaula realpath en /var/www/vhosts/<dominio>/,
 * escritura solo dentro de httpdocs, nunca ejecuta ni sirve PHP como código (readfile + nosniff).
 */
declare(strict_types=1);
require __DIR__ . '/auth.php';
fresk_require_login();
require __DIR__ . '/includes/layout.php';

require_once __DIR__ . '/includes/fm.php';

// ------------------------------------------------------------------ API
$api = (string)($_GET['api'] ?? $_POST['api'] ?? '');
$domains = fm_domains();
$domain = null;
$reqDomain = (string)($_GET['domain'] ?? $_POST['domain'] ?? '');
if ($reqDomain !== '') {
    $d = fresk_valid_domain($reqDomain);
    if ($d !== null && in_array($d, $domains, true)) $domain = $d;
}

if ($api !== '') {
    try {
        if ($domain === null) throw new FmError(t('fm.err_notfound'));
        $root = fm_root($domain);
        $isPost = $_SERVER['REQUEST_METHOD'] === 'POST';
        if ($isPost) fresk_csrf_check();
        $path = (string)($_GET['path'] ?? $_POST['path'] ?? '');

        switch ($api) {
            case 'list': {
                $real = fm_resolve($root, $path);
                if (!is_dir($real)) throw new FmError(t('fm.err_path'));
                if (!is_readable($real)) throw new FmError(t('fm.err_perm'));
                $out = [];
                $zone = null;
                try { $zone = fm_write_zone($root); } catch (FmError) { $zone = null; }
                $names = @scandir($real) ?: [];
                foreach ($names as $n) {
                    if ($n === '.' || $n === '..') continue;
                    if (count($out) >= FM_LIST_MAX) break;
                    $full = $real . '/' . $n;
                    $e = fm_entry($full, $root);
                    // symlinks: se muestran solo si apuntan dentro de la jaula
                    if ($e['link']) {
                        $t = realpath($full);
                        if ($t === false || !fm_inside($t, $root)) continue;
                    }
                    $e['path'] = fm_rel($real, $root) === '' ? $n : fm_rel($real, $root) . '/' . $n;
                    $e['writable'] = $zone !== null && str_starts_with($real . '/' . $n, $zone . '/');
                    $out[] = $e;
                }
                usort($out, static fn($a, $b) => [$a['type'] !== 'dir', strtolower($a['name'])] <=> [$b['type'] !== 'dir', strtolower($b['name'])]);
                fm_json(['ok' => true, 'path' => fm_rel($real, $root), 'entries' => $out,
                    'writable' => $zone !== null && ($real === $zone || str_starts_with($real, $zone . '/'))]);
            }
            case 'read': {
                $real = fm_resolve($root, $path);
                if (!is_file($real)) throw new FmError(t('fm.err_path'));
                if (!is_readable($real)) throw new FmError(t('fm.err_perm'));
                $e = fm_entry($real, $root);
                $e['path'] = fm_norm($path);
                try { fm_assert_writable_zone($real, $root); $e['writable'] = true; } catch (FmError) { $e['writable'] = false; }
                $size = (int)filesize($real);
                if ($size > FM_EDIT_MAX) fm_json(['ok' => true, 'file' => $e, 'text' => false, 'reason' => t('fm.too_big')]);
                $data = (string)file_get_contents($real);
                if (str_contains(substr($data, 0, 8192), "\0") || !mb_check_encoding($data, 'UTF-8')) {
                    fm_json(['ok' => true, 'file' => $e, 'text' => false, 'reason' => t('fm.binary')]);
                }
                fm_json(['ok' => true, 'file' => $e, 'text' => true, 'content' => $data]);
            }
            case 'raw': {
                $real = fm_resolve($root, $path);
                if (!is_file($real) || !is_readable($real)) throw new FmError(t('fm.err_notfound'));
                $name = basename($real);
                [$mime, $inlineOk] = fm_safe_mime($name);
                $dl = !empty($_GET['dl']) || !$inlineOk;
                header('Content-Type: ' . $mime);
                header('X-Content-Type-Options: nosniff');
                header('Cache-Control: private, no-store');
                header('Content-Length: ' . (string)filesize($real));
                $csp = "default-src 'none'; img-src 'self' data:; media-src 'self'; style-src 'unsafe-inline'";
                if ($mime !== 'application/pdf') $csp .= '; sandbox';
                header('Content-Security-Policy: ' . $csp);
                $enc = rawurlencode($name);
                $ascii = preg_replace('/[^A-Za-z0-9._-]/', '_', $name);
                header('Content-Disposition: ' . ($dl ? 'attachment' : 'inline') . "; filename=\"{$ascii}\"; filename*=UTF-8''{$enc}");
                readfile($real);
                exit;
            }
            case 'save': {
                if (!$isPost) throw new FmError(t('fm.err_generic'));
                $real = fm_resolve($root, $path);
                if (!is_file($real)) throw new FmError(t('fm.err_path'));
                fm_assert_writable_zone($real, $root);
                $content = (string)($_POST['content'] ?? '');
                if (strlen($content) > FM_EDIT_MAX) throw new FmError(t('fm.too_big'));
                if (!is_writable($real)) fm_fixperms($domain, $real, $root);
                if (!is_writable($real) || @file_put_contents($real, $content, LOCK_EX) === false) throw new FmError(t('fm.err_perm'));
                clearstatcache(true, $real);
                fresk_audit('files.save', $domain . ':' . fm_rel($real, $root), 'ok', 'bytes=' . strlen($content));
                fm_json(['ok' => true, 'message' => t('fm.saved'), 'file' => fm_entry($real, $root)]);
            }
            case 'mkdir':
            case 'newfile': {
                if (!$isPost) throw new FmError(t('fm.err_generic'));
                $name = trim((string)($_POST['name'] ?? ''));
                if (!fm_valid_name($name)) throw new FmError(t('fm.err_name'));
                $parent = fm_resolve($root, $path);
                if (!is_dir($parent)) throw new FmError(t('fm.err_path'));
                $zone = fm_write_zone($root);
                if ($parent !== $zone && !str_starts_with($parent, $zone . '/')) throw new FmError(t('fm.err_write_zone'));
                $target = $parent . '/' . $name;
                if (file_exists($target) || is_link($target)) throw new FmError(t('fm.err_exists'));
                $ok = $api === 'mkdir' ? @mkdir($target, 02775) : (@file_put_contents($target, '', LOCK_EX) !== false);
                if (!$ok) throw new FmError(t('fm.err_perm'));
                fm_fixperms($domain, $target, $root);
                fresk_audit('files.' . $api, $domain . ':' . fm_rel($target, $root), 'ok');
                fm_json(['ok' => true, 'message' => t('fm.ok_created'), 'path' => fm_rel($target, $root)]);
            }
            case 'rename': {
                if (!$isPost) throw new FmError(t('fm.err_generic'));
                $name = trim((string)($_POST['name'] ?? ''));
                if (!fm_valid_name($name)) throw new FmError(t('fm.err_name'));
                $rel = fm_norm($path);
                if ($rel === '') throw new FmError(t('fm.err_path'));
                $src = $root . '/' . $rel;                       // no seguir symlink final: se renombra el enlace
                $parent = realpath(dirname($src));
                if ($parent === false || !fm_inside($parent, $root)) throw new FmError(t('fm.err_path'));
                $src = $parent . '/' . basename($src);
                if (!file_exists($src) && !is_link($src)) throw new FmError(t('fm.err_notfound'));
                fm_assert_writable_zone($src, $root);
                $dst = $parent . '/' . $name;
                if (file_exists($dst) || is_link($dst)) throw new FmError(t('fm.err_exists'));
                if (!@rename($src, $dst)) throw new FmError(t('fm.err_perm'));
                fresk_audit('files.rename', $domain . ':' . fm_rel($src, $root), 'ok', 'to=' . $name);
                fm_json(['ok' => true, 'message' => t('fm.ok_renamed'), 'path' => fm_rel($dst, $root)]);
            }
            case 'delete': {
                if (!$isPost) throw new FmError(t('fm.err_generic'));
                $rel = fm_norm($path);
                if ($rel === '') throw new FmError(t('fm.err_path'));
                $src = $root . '/' . $rel;
                $parent = realpath(dirname($src));
                if ($parent === false || !fm_inside($parent, $root)) throw new FmError(t('fm.err_path'));
                $src = $parent . '/' . basename($src);
                if (!file_exists($src) && !is_link($src)) throw new FmError(t('fm.err_notfound'));
                fm_assert_writable_zone($src, $root);
                if (is_link($src) || is_file($src)) {
                    if (!@unlink($src)) throw new FmError(t('fm.err_perm'));
                } else {
                    fm_rmtree($src);
                }
                fresk_audit('files.delete', $domain . ':' . $rel, 'ok');
                fm_json(['ok' => true, 'message' => t('fm.ok_deleted')]);
            }
            case 'upload': {
                if (!$isPost) throw new FmError(t('fm.err_generic'));
                $parent = fm_resolve($root, $path);
                if (!is_dir($parent)) throw new FmError(t('fm.err_path'));
                $zone = fm_write_zone($root);
                if ($parent !== $zone && !str_starts_with($parent, $zone . '/')) throw new FmError(t('fm.err_write_zone'));
                $files = $_FILES['files'] ?? null;
                if (!is_array($files) || !isset($files['name'])) throw new FmError(t('fm.err_upload_size', fm_human_bytes(fm_upload_limit())));
                $names = (array)$files['name'];
                $n = 0;
                foreach ($names as $i => $orig) {
                    $err = (int)((array)$files['error'])[$i];
                    if ($err === UPLOAD_ERR_INI_SIZE || $err === UPLOAD_ERR_FORM_SIZE) throw new FmError(t('fm.err_upload_size', fm_human_bytes(fm_upload_limit())));
                    if ($err !== UPLOAD_ERR_OK) throw new FmError(t('fm.err_upload'));
                    $tmp = (string)((array)$files['tmp_name'])[$i];
                    $size = (int)((array)$files['size'])[$i];
                    if ($size > FM_UPLOAD_MAX) throw new FmError(t('fm.err_upload_size', fm_human_bytes(FM_UPLOAD_MAX)));
                    $name = basename(str_replace('\\', '/', (string)$orig));
                    if (!fm_valid_name($name)) throw new FmError(t('fm.err_name') . ' (' . $name . ')');
                    $target = $parent . '/' . $name;
                    if (is_link($target) || is_dir($target)) throw new FmError(t('fm.err_exists'));
                    if (file_exists($target) && !is_writable($target)) fm_fixperms($domain, $target, $root);
                    if (!is_uploaded_file($tmp) || !@move_uploaded_file($tmp, $target)) throw new FmError(t('fm.err_perm'));
                    fm_fixperms($domain, $target, $root);
                    fresk_audit('files.upload', $domain . ':' . fm_rel($target, $root), 'ok', 'bytes=' . $size);
                    $n++;
                }
                fm_json(['ok' => true, 'message' => t('fm.ok_uploaded', $n)]);
            }
            case 'zipcheck':
            case 'zip': {
                // Solo POST con CSRF (comprobado arriba); admin logueado (fresk_require_login)
                if (!$isPost) throw new FmError(t('fm.err_generic'));
                if (!class_exists('ZipArchive')) throw new FmError(t('fm.zip_unavailable'));
                $real = fm_resolve($root, $path);
                if (!is_dir($real)) throw new FmError(t('fm.err_path'));
                if (!is_readable($real)) throw new FmError(t('fm.err_perm'));
                $folder = $real === $root ? $domain : basename($real);
                @set_time_limit(900);
                [$entries, $bytes, $count] = fm_zip_collect($real, $root, $folder);
                if ($api === 'zipcheck') {
                    fm_json(['ok' => true, 'files' => $count, 'size' => $bytes, 'sizeH' => fm_human_bytes($bytes), 'name' => $folder . '.zip']);
                }
                $tmp = fm_zip_build($entries);
                fresk_audit('files.zip', $domain . ':' . (fm_rel($real, $root) ?: '/'), 'ok', 'files=' . $count . ' bytes=' . $bytes);
                fm_zip_send($tmp, $folder . '.zip');
            }
            case 'zipmulticheck':
            case 'zipmulti': {
                if (!$isPost) throw new FmError(t('fm.err_generic'));
                if (!class_exists('ZipArchive')) throw new FmError(t('fm.zip_unavailable'));
                $rels = fm_prune_nested(fm_post_paths());
                // Validación completa antes de actuar (todo o nada)
                $errors = []; $items = [];
                foreach ($rels as $rel) {
                    try {
                        $real = fm_resolve($root, $rel);
                        if (!is_readable($real)) throw new FmError(t('fm.err_perm'));
                        $items[] = [$rel, $real];
                    } catch (FmError $e) { $errors[] = ['path' => $rel, 'error' => $e->getMessage()]; }
                }
                if ($errors) fm_json(['ok' => false, 'error' => t('fm.err_some_invalid'), 'items' => $errors], 400);
                [$maxBytes, $maxFiles] = fm_zip_limits();
                $common = fm_common_parent($rels);
                $cut = $common === '' ? 0 : strlen($common) + 1;
                @set_time_limit(900);
                $entries = []; $bytes = 0; $count = 0;
                foreach ($items as [$rel, $real]) {
                    $arc = substr($rel, $cut);
                    if ($arc === '' || $arc === false) $arc = $domain;
                    if (is_dir($real)) {
                        [$e, $b, $c] = fm_zip_collect($real, $root, $arc);
                        $entries = array_merge($entries, $e); $bytes += $b; $count += $c;
                    } elseif (is_file($real)) {
                        $entries[] = [$real, $arc]; $bytes += (int)@filesize($real); $count++;
                    }
                    if ($count > $maxFiles) throw new FmError(t('fm.zip_too_many', $maxFiles));
                    if ($bytes > $maxBytes) throw new FmError(t('fm.zip_too_big', fm_human_bytes($maxBytes)));
                }
                $zname = ($common === '' ? $domain : basename($common)) . '-' . t('fm.selection_slug') . '.zip';
                if ($api === 'zipmulticheck') {
                    fm_json(['ok' => true, 'files' => $count, 'size' => $bytes, 'sizeH' => fm_human_bytes($bytes), 'name' => $zname]);
                }
                $tmp = fm_zip_build($entries);
                fresk_audit('files.zip', $domain . ':' . implode(',', array_slice($rels, 0, 20)), 'ok', 'items=' . count($rels) . ' files=' . $count . ' bytes=' . $bytes);
                fm_zip_send($tmp, $zname);
            }
            case 'deletemulti': {
                if (!$isPost) throw new FmError(t('fm.err_generic'));
                $rels = fm_prune_nested(fm_post_paths());
                // 1) Validar todo antes de borrar nada
                $errors = []; $targets = [];
                foreach ($rels as $rel) {
                    try {
                        if ($rel === '') throw new FmError(t('fm.err_path'));
                        $src = $root . '/' . $rel;
                        $parent = realpath(dirname($src));
                        if ($parent === false || !fm_inside($parent, $root)) throw new FmError(t('fm.err_path'));
                        $src = $parent . '/' . basename($src);
                        if (!file_exists($src) && !is_link($src)) throw new FmError(t('fm.err_notfound'));
                        fm_assert_writable_zone($src, $root);
                        $targets[] = [$rel, $src];
                    } catch (FmError $e) { $errors[] = ['path' => $rel, 'error' => $e->getMessage()]; }
                }
                if ($errors) fm_json(['ok' => false, 'error' => t('fm.err_some_invalid'), 'items' => $errors], 400);
                // 2) Borrar, informando por elemento
                $report = []; $okN = 0;
                foreach ($targets as [$rel, $src]) {
                    try {
                        if (is_link($src) || is_file($src)) {
                            if (!@unlink($src)) throw new FmError(t('fm.err_perm'));
                        } else {
                            fm_rmtree($src);
                        }
                        $okN++;
                        $report[] = ['path' => $rel, 'ok' => true];
                        fresk_audit('files.delete', $domain . ':' . $rel, 'ok', 'multi');
                    } catch (FmError $e) {
                        $report[] = ['path' => $rel, 'ok' => false, 'error' => $e->getMessage()];
                        fresk_audit('files.delete', $domain . ':' . $rel, 'error', $e->getMessage());
                    }
                }
                $all = $okN === count($targets);
                fm_json(['ok' => $all, 'message' => t('fm.ok_deleted_n', $okN, count($targets)), 'error' => $all ? null : t('fm.ok_deleted_n', $okN, count($targets)), 'items' => $report], $all ? 200 : 207);
            }
            default:
                throw new FmError(t('fm.err_generic'));
        }
    } catch (FmError $e) {
        fm_json(['ok' => false, 'error' => $e->getMessage()], 400);
    } catch (Throwable $e) {
        error_log('flesk files: ' . $e->getMessage());
        fm_json(['ok' => false, 'error' => t('fm.err_generic')], 500);
    }
}

// ------------------------------------------------------------------ Página
if ($domain === null && $domains !== []) $domain = $domains[0];
$base = fresk_base();
$cfg = [
    'base' => $base . '/files.php',
    'domain' => $domain,
    'csrf' => fresk_csrf_token(),
    'uploadMax' => fm_upload_limit(),
    'uploadMaxH' => fm_human_bytes(fm_upload_limit()),
    'i18n' => [],
];
foreach (['fm.new_file', 'fm.new_folder', 'fm.upload', 'fm.download', 'fm.rename', 'fm.delete', 'fm.save', 'fm.saved',
          'fm.unsaved', 'fm.drop', 'fm.size', 'fm.modified', 'fm.readonly', 'fm.no_preview', 'fm.ask_name',
          'fm.ask_new_name', 'fm.confirm_delete', 'fm.confirm_close', 'fm.loading', 'fm.err_generic', 'fm.target',
          'fm.err_upload_size', 'fm.empty', 'fm.zip', 'fm.zip_folder', 'fm.zip_preparing', 'fm.n_selected', 'fm.select_all', 'fm.clear_selection', 'fm.confirm_delete_n', 'fm.cancel', 'fm.select'] as $k) {
    $cfg['i18n'][$k] = t($k);
}

fresk_layout_start(t('page.files'), 'files');
?>
<link rel="stylesheet" href="<?= fresk_asset('vendor/codemirror/codemirror.css') ?>">
<div class="d-flex justify-content-between align-items-center mb-3 flex-wrap gap-2">
  <h1 class="h4 mb-0"><i class="bi bi-folder2-open me-2"></i><?= te('page.files') ?></h1>
  <?php if ($domains): ?>
  <form method="get" class="d-flex align-items-center gap-2">
    <label class="small text-muted" for="fmDomain"><?= te('fm.domain') ?></label>
    <select class="form-select form-select-sm" id="fmDomain" name="domain" onchange="this.form.submit()" style="min-width:220px">
      <?php foreach ($domains as $d): ?>
        <option value="<?= fresk_h($d) ?>"<?= $d === $domain ? ' selected' : '' ?>><?= fresk_h($d) ?></option>
      <?php endforeach; ?>
    </select>
  </form>
  <?php endif; ?>
</div>
<?php if (!$domains): ?>
  <div class="card fresk-card"><div class="card-body text-muted"><?= te('fm.no_domains') ?></div></div>
<?php else: ?>
<div class="card fresk-card fm-shell" id="fmShell">
  <div class="fm-toolbar">
    <div class="d-flex align-items-center gap-1 flex-wrap">
      <button class="btn btn-sm btn-light" type="button" data-fm="newfile" title="<?= te('fm.new_file') ?>"><i class="bi bi-file-earmark-plus"></i><span class="d-none d-md-inline"> <?= te('fm.new_file') ?></span></button>
      <button class="btn btn-sm btn-light" type="button" data-fm="mkdir" title="<?= te('fm.new_folder') ?>"><i class="bi bi-folder-plus"></i><span class="d-none d-md-inline"> <?= te('fm.new_folder') ?></span></button>
      <button class="btn btn-sm btn-light" type="button" data-fm="upload" title="<?= te('fm.upload') ?>"><i class="bi bi-cloud-arrow-up"></i><span class="d-none d-md-inline"> <?= te('fm.upload') ?></span></button>
      <button class="btn btn-sm btn-light" type="button" data-fm="zip" title="<?= te('fm.zip_folder') ?>"><i class="bi bi-file-earmark-zip"></i><span class="d-none d-md-inline"> <?= te('fm.zip') ?></span></button>
      <button class="btn btn-sm btn-light" type="button" data-fm="refresh" title="<?= te('fm.refresh') ?>"><i class="bi bi-arrow-clockwise"></i></button>
      <input type="file" id="fmUploadInput" multiple hidden>
    </div>
    <div class="fm-selbar" id="fmSelBar" hidden role="region" aria-live="polite">
      <span class="fw-semibold" id="fmSelCount"></span>
      <button class="btn btn-sm btn-fresk-primary" type="button" id="fmSelDownload"><i class="bi bi-download me-1"></i><?= te('fm.download') ?></button>
      <button class="btn btn-sm btn-outline-danger" type="button" id="fmSelDelete"><i class="bi bi-trash me-1"></i><?= te('fm.delete') ?></button>
      <button class="btn btn-sm btn-link text-secondary" type="button" id="fmSelClear" title="<?= te('fm.clear_selection') ?>" aria-label="<?= te('fm.clear_selection') ?>"><i class="bi bi-x-lg"></i></button>
    </div>
    <div class="small text-muted text-truncate"><i class="bi bi-folder2 me-1"></i><?= te('fm.target') ?>: <code id="fmTarget">/</code></div>
  </div>
  <div class="fm-body">
    <aside class="fm-tree" id="fmTree" aria-label="<?= te('page.files') ?>">
      <div class="fm-tree-root d-flex align-items-center"><input class="form-check-input fm-check me-2" type="checkbox" id="fmSelAll" aria-label="<?= te('fm.select_all') ?>" title="<?= te('fm.select_all') ?>"><span class="text-truncate flex-grow-1" role="button" data-fm-root title="/"><i class="bi bi-hdd-network me-1"></i><?= fresk_h((string)$domain) ?></span>
        <button type="button" class="fm-zip-btn" data-fm-zip="" title="<?= te('fm.zip_folder') ?>: <?= fresk_h((string)$domain) ?>" aria-label="<?= te('fm.zip_folder') ?>: <?= fresk_h((string)$domain) ?>"><i class="bi bi-file-earmark-zip"></i></button></div>
      <ul class="fm-list" id="fmRootList"></ul>
    </aside>
    <section class="fm-main">
      <div class="fm-tabs" id="fmTabs" role="tablist"></div>
      <div class="fm-view" id="fmView">
        <div class="fm-empty" id="fmEmpty">
          <?= fresk_logo_svg('fme') ?>
          <p class="mb-1"><?= te('fm.empty') ?></p>
          <p class="small text-muted mb-0"><?= te('fm.empty_hint') ?></p>
        </div>
      </div>
      <div class="fm-status" id="fmStatus"></div>
    </section>
  </div>
  <div class="fm-drop" id="fmDrop"><div><i class="bi bi-cloud-arrow-up"></i><p class="mb-0"><?= te('fm.drop') ?> <code id="fmDropTarget">/</code></p></div></div>
</div>
<div class="modal fade" id="fmDelModal" tabindex="-1" aria-labelledby="fmDelTitle" aria-hidden="true">
  <div class="modal-dialog modal-dialog-scrollable">
    <div class="modal-content">
      <div class="modal-header">
        <h5 class="modal-title text-danger" id="fmDelTitle"><i class="bi bi-trash me-2"></i><span id="fmDelTitleN"></span></h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="<?= te('fm.cancel') ?>"></button>
      </div>
      <div class="modal-body">
        <p class="small text-muted"><?= te('fm.delete_multi_help') ?></p>
        <ul class="list-unstyled small fm-del-list mb-0" id="fmDelList"></ul>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal"><?= te('fm.cancel') ?></button>
        <button type="button" class="btn btn-fresk-danger" id="fmDelGo"><?= te('fm.delete') ?></button>
      </div>
    </div>
  </div>
</div>
<script>window.FLESK_FM = <?= json_encode($cfg, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT) ?>;</script>
<script src="<?= fresk_asset('vendor/codemirror/codemirror-bundle.min.js') ?>"></script>
<script src="<?= fresk_asset_v('js/fresk-files.js') ?>"></script>
<?php endif; ?>
<?php fresk_layout_end(); ?>
