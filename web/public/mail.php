<?php
declare(strict_types=1);
require __DIR__ . '/auth.php';
fresk_require_login();
require __DIR__ . '/includes/layout.php';
require __DIR__ . '/includes/webmail_ssl.php';

$flash = '';
$flashErr = '';
$shownPassword = null;

$pdo = fresk_pdo();
$domainList = $pdo->query(
    'SELECT d.name, COUNT(m.id) AS n FROM domains d LEFT JOIN mailboxes m ON m.domain_id = d.id
     GROUP BY d.id, d.name ORDER BY d.name'
)->fetchAll();
$domainNames = array_map('strval', array_column($domainList, 'name'));

/** URL del webmail Roundcube del dominio: https salvo que su vhost exista y solo sirva HTTP. */
$webmailUrl = static function (string $email): string {
    $dom = strtolower((string)substr((string)strrchr($email, '@'), 1));
    if (fresk_valid_domain($dom) === null) return '';
    $dir = rtrim((string)(fresk_cfg()['NGINX_ENABLED'] ?? '/etc/nginx/fresk-enabled'), '/');
    $vf = $dir . '/' . $dom . '.webmail.conf';
    $scheme = 'https';
    if (is_file($vf) && is_readable($vf)) {
        $c = (string)@file_get_contents($vf);
        if ($c !== '' && !preg_match('/listen\s+[^;]*443/', $c)) $scheme = 'http';
    }
    return $scheme . '://webmail.' . $dom . '/';
};

/** Parte local segura: minúsculas, dígitos y . _ + - ; sin punto al inicio/fin ni dobles. */
$validLocal = static function (string $v): ?string {
    $v = strtolower(trim($v));
    if ($v === '' || strlen($v) > 64) return null;
    if (!preg_match('/^[a-z0-9](?:[a-z0-9._+\-]*[a-z0-9])?$/', $v) || str_contains($v, '..')) return null;
    return $v;
};
/** Construye local@dominio; el dominio debe existir en la BD. */
$buildAddress = static function (string $local, string $domain) use ($validLocal, $domainNames): array {
    $l = $validLocal($local);
    if ($l === null) return [null, t('mail.err_local')];
    $d = fresk_valid_domain(strtolower(trim($domain)));
    if ($d === null || !in_array($d, $domainNames, true)) return [null, t('mail.err_domain')];
    $e = fresk_valid_email($l . '@' . $d);
    return $e === null ? [null, t('mail.err_local')] : [$e, ''];
};

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    fresk_csrf_check();
    $action = (string)($_POST['action'] ?? '');

    if ($action === 'mail_add') {
        [$email, $err] = $buildAddress((string)($_POST['local_part'] ?? ''), (string)($_POST['domain'] ?? ''));
        $quota = (int)($_POST['quota'] ?? 1024);
        $pw = (string)($_POST['password'] ?? '');
        $pwProblems = fresk_password_problems($pw);
        if ($email === null) {
            $flashErr = $err;
        } elseif ($quota < 1 || $quota > 1048576) {
            $flashErr = t('mail.err_quota');
        } elseif ($pwProblems || preg_match('/[\r\n\0]/', $pw)) {
            $flashErr = t('mail.err_pw', implode(', ', array_map(static fn($k) => t($k), $pwProblems ?: ['pw.len'])));
        } else {
            // La contraseña va por stdin (--password-stdin), nunca en argv
            $r = fresk_cli(['mail', 'add', $email, '--quota', (string)$quota, '--password-stdin'], $pw);
            if ($r['code'] === 0) {
                $flash = t('mail.created', $email);
            } else {
                $flashErr = t('mail.err_create', (string)$r['code'], trim($r['stderr'] . ' ' . $r['stdout']));
            }
        }
    } elseif ($action === 'mail_passwd') {
        $email = fresk_valid_email((string)($_POST['email'] ?? ''));
        if ($email === null) {
            $flashErr = 'Email inválido';
        } else {
            $r = fresk_cli(['mail', 'passwd', $email]);
            if ($r['code'] === 0) {
                $flash = 'Contraseña regenerada: ' . $email;
                $shownPassword = $r['password'] ?? fresk_extract_password($r['stdout']);
            } else {
                $flashErr = 'Error passwd (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
            }
        }
    } elseif ($action === 'mail_del') {
        $email = fresk_valid_email((string)($_POST['email'] ?? ''));
        $confirm = strtolower(trim((string)($_POST['confirm'] ?? '')));
        if ($email === null) {
            $flashErr = 'Email inválido';
        } elseif ($confirm !== $email) {
            $flashErr = 'Escribe el email completo para confirmar la baja';
        } else {
            $args = ['mail', 'del', $email];
            if (!empty($_POST['keep_data'])) $args[] = '--keep-data';
            $r = fresk_cli($args);
            if ($r['code'] === 0) {
                $flash = 'Buzón eliminado: ' . $email;
            } else {
                $flashErr = 'Error al eliminar (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
            }
        }
    } elseif ($action === 'alias_add') {
        if (isset($_POST['local_part'])) {
            [$src, $err] = $buildAddress((string)$_POST['local_part'], (string)($_POST['domain'] ?? ''));
        } else {
            $src = fresk_valid_email((string)($_POST['source'] ?? ''));
            $err = t('mail.err_alias');
        }
        $dst = fresk_valid_destination((string)($_POST['destination'] ?? ''));
        if ($src === null || $dst === null) {
            $flashErr = $src === null ? $err : t('mail.err_alias');
        } else {
            $r = fresk_cli(['alias', 'add', $src, $dst]);
            if ($r['code'] === 0) {
                $flash = "Alias $src → $dst";
            } else {
                $flashErr = 'Error alias (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
            }
        }
    } elseif ($action === 'alias_del') {
        $src = fresk_valid_email((string)($_POST['source'] ?? ''));
        $dstRaw = trim((string)($_POST['destination'] ?? ''));
        $dst = $dstRaw !== '' ? fresk_valid_destination($dstRaw) : null;
        if ($src === null) {
            $flashErr = 'Origen inválido';
        } elseif ($dstRaw !== '' && $dst === null) {
            $flashErr = 'Destino inválido';
        } else {
            $args = ['alias', 'del', $src];
            if ($dst !== null) $args[] = $dst;
            $r = fresk_cli($args);
            if ($r['code'] === 0) {
                $flash = 'Alias eliminado: ' . $src;
            } else {
                $flashErr = 'Error alias del (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
            }
        }
    } elseif ($action === 'forward_add') {
        $mb = fresk_valid_email((string)($_POST['mailbox'] ?? ''));
        $dst = fresk_valid_destination((string)($_POST['destination'] ?? ''));
        if ($mb === null || $dst === null) {
            $flashErr = 'Buzón o destino de reenvío inválido';
        } else {
            $r = fresk_cli(['forward', 'add', $mb, $dst]);
            if ($r['code'] === 0) {
                $flash = "Reenvío $mb → $dst (copia local)";
            } else {
                $flashErr = 'Error forward (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
            }
        }
    } elseif ($action === 'forward_del') {
        $mb = fresk_valid_email((string)($_POST['mailbox'] ?? ''));
        $dstRaw = trim((string)($_POST['destination'] ?? ''));
        $dst = $dstRaw !== '' ? fresk_valid_destination($dstRaw) : null;
        if ($mb === null) {
            $flashErr = 'Buzón inválido';
        } elseif ($dstRaw !== '' && $dst === null) {
            $flashErr = 'Destino inválido';
        } else {
            $args = ['forward', 'del', $mb];
            if ($dst !== null) $args[] = $dst;
            $r = fresk_cli($args);
            if ($r['code'] === 0) {
                $flash = 'Reenvío eliminado: ' . $mb;
            } else {
                $flashErr = 'Error forward del (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
            }
        }
    } elseif ($action === 'webmail_ssl') {
        $wd = fresk_valid_domain(strtolower(trim((string)($_POST['domain'] ?? ''))));
        if ($wd === null || !in_array($wd, $domainNames, true)) {
            $flashErr = t('mail.err_domain');
        } else {
            [$flash, $flashErr] = fresk_webmail_ssl_issue($wd);
        }
    } elseif ($action === 'mail_vacation') {
        // Contestador automático (Dovecot Sieve vacation); los datos van por stdin en JSON
        $email = fresk_valid_email((string)($_POST['email'] ?? ''));
        if ($email === null || !in_array($email, $pdo->query("SELECT CONCAT(m.local_part,'@',d.name) FROM mailboxes m JOIN domains d ON d.id = m.domain_id")->fetchAll(PDO::FETCH_COLUMN), true)) {
            $flashErr = t('mail.vac_err_mailbox');
        } else {
            $payload = json_encode([
                'enabled' => !empty($_POST['vac_enabled']),
                'subject' => trim((string)($_POST['vac_subject'] ?? '')),
                'body'    => (string)($_POST['vac_body'] ?? ''),
                'html'    => ($_POST['vac_format'] ?? 'text') === 'html',
                'start'   => trim((string)($_POST['vac_start'] ?? '')),
                'end'     => trim((string)($_POST['vac_end'] ?? '')),
            ], JSON_UNESCAPED_UNICODE);
            $r = fresk_cli(['mail', 'vacation', 'set', $email], $payload === false ? '' : $payload);
            if ($r['code'] === 0) {
                $flash = t(!empty($_POST['vac_enabled']) ? 'mail.vac_saved_on' : 'mail.vac_saved_off', $email);
            } else {
                $msg = trim($r['stderr'] . ' ' . $r['stdout']);
                $flashErr = t('mail.vac_err', trim(preg_replace('/^.*?ERROR:\s*/s', '', $msg) ?? $msg));
            }
        }
    } else {
        $flashErr = 'Acción desconocida';
    }
}

// Filtros (GET): domain = dominio exacto, q = texto en email
// Recargar recuentos tras un POST (pudo crearse/borrarse un buzón)
$domainList = $pdo->query(
    'SELECT d.name, COUNT(m.id) AS n FROM domains d LEFT JOIN mailboxes m ON m.domain_id = d.id
     GROUP BY d.id, d.name ORDER BY d.name'
)->fetchAll();
$allMailboxes = $pdo->query(
    "SELECT CONCAT(m.local_part,'@',d.name) AS email FROM mailboxes m JOIN domains d ON d.id = m.domain_id ORDER BY d.name, m.local_part"
)->fetchAll(PDO::FETCH_COLUMN);
$fdom = null;
if (isset($_GET['domain']) && is_string($_GET['domain']) && $_GET['domain'] !== '') {
    $cand = fresk_valid_domain($_GET['domain']);
    if ($cand !== null && in_array($cand, array_column($domainList, 'name'), true)) {
        $fdom = $cand;
    }
}
$fq = mb_substr(strtolower(trim((string)($_GET['q'] ?? ''))), 0, 255);
$fq = preg_replace('/[^a-z0-9@._+\-]/', '', $fq) ?? '';
$like = '%' . addcslashes($fq, '%_\\') . '%';
$mailUrl = static function (?string $dom, string $q = ''): string {
    $qs = array_filter(['domain' => $dom ?? '', 'q' => $q], static fn($v) => $v !== '');
    return fresk_base() . '/mail.php' . ($qs ? '?' . http_build_query($qs) : '');
};

$w = []; $p = [];
if ($fdom !== null) { $w[] = 'd.name = ?'; $p[] = $fdom; }
if ($fq !== '') { $w[] = "CONCAT(m.local_part,'@',d.name) LIKE ?"; $p[] = $like; }
$st = $pdo->prepare(
    "SELECT m.id, CONCAT(m.local_part,'@',d.name) AS email, d.name AS domain, m.quota_mb, m.maildir, m.active, m.created_at,
            v.enabled AS vac_enabled, v.subject AS vac_subject, v.body AS vac_body, v.is_html AS vac_html, v.start_date AS vac_start, v.end_date AS vac_end
     FROM mailboxes m JOIN domains d ON d.id = m.domain_id LEFT JOIN mail_vacation v ON v.mailbox_id = m.id"
    . ($w ? ' WHERE ' . implode(' AND ', $w) : '') . ' ORDER BY d.name, m.local_part'
);
$st->execute($p);
$mailboxes = $st->fetchAll();

$w = []; $p = [];
if ($fdom !== null) { $w[] = 'd.name = ?'; $p[] = $fdom; }
if ($fq !== '') { $w[] = '(a.source LIKE ? OR a.destination LIKE ?)'; $p[] = $like; $p[] = $like; }
$st = $pdo->prepare(
    "SELECT a.id, a.source, a.destination, d.name AS domain, a.active
     FROM aliases a JOIN domains d ON d.id = a.domain_id"
    . ($w ? ' WHERE ' . implode(' AND ', $w) : '') . ' ORDER BY a.source'
);
$st->execute($p);
$aliases = $st->fetchAll();

$w = []; $p = [];
if ($fdom !== null) { $w[] = 'd.name = ?'; $p[] = $fdom; }
if ($fq !== '') { $w[] = "(CONCAT(m.local_part,'@',d.name) LIKE ? OR f.destination LIKE ?)"; $p[] = $like; $p[] = $like; }
$st = $pdo->prepare(
    "SELECT f.id, CONCAT(m.local_part,'@',d.name) AS mailbox, f.destination, f.active
     FROM forwards f
     JOIN mailboxes m ON m.id = f.mailbox_id
     JOIN domains d ON d.id = m.domain_id"
    . ($w ? ' WHERE ' . implode(' AND ', $w) : '') . ' ORDER BY mailbox'
);
$st->execute($p);
$forwards = $st->fetchAll();
$filtered = ($fdom !== null || $fq !== '');
$phDomain = $fdom ?? 'ejemplo.com';

/** '@' + dominio: fijo si hay filtro activo; si no, select preseleccionado. */
$domainPicker = static function (string $id) use ($domainList, $fdom): string {
    if ($fdom !== null) {
        return '<span class="input-group-text">@' . fresk_h($fdom) . '</span>'
             . '<input type="hidden" name="domain" value="' . fresk_h($fdom) . '">';
    }
    $h = '<span class="input-group-text">@</span><select class="form-select fresk-domain-pick" id="' . fresk_h($id) . '" name="domain" required aria-label="' . te('mail.domain') . '">';
    foreach ($domainList as $dl) {
        $h .= '<option value="' . fresk_h((string)$dl['name']) . '">' . fresk_h((string)$dl['name']) . '</option>';
    }
    return $h . '</select>';
};

fresk_layout_start('Correo', 'mail');
fresk_render_flashes($flash, $flashErr, $shownPassword);
?>
<div class="d-flex justify-content-between align-items-center mb-3 flex-wrap gap-2">
  <h1 class="h4 mb-0"><?= te('page.mail') ?></h1>
  <button type="button" class="btn btn-fresk-primary btn-sm" data-bs-toggle="modal" data-bs-target="#modalAddMail">
    <i class="bi bi-plus-lg"></i> Añadir buzón
  </button>
</div>

<div class="card fresk-card fresk-filter-bar mb-3">
  <div class="card-body py-2">
    <form method="get" role="search" class="fresk-toolbar d-flex flex-wrap flex-md-nowrap align-items-center gap-2" aria-label="<?= te('filter.title') ?>">
      <div class="input-group input-group-sm fresk-toolbar-search flex-grow-1">
        <span class="input-group-text"><i class="bi bi-search"></i></span>
        <input class="form-control" type="search" id="mq" name="q" value="<?= fresk_h($fq) ?>" placeholder="<?= te('filter.q_email') ?>" aria-label="<?= te('filter.q_email') ?>" autocomplete="off" data-live-filter=".mail-filterable, .mail-filterable-sub">
      </div>
      <select class="form-select form-select-sm w-auto fresk-toolbar-select" id="mdom" name="domain" aria-label="<?= te('filter.domain') ?>" onchange="this.form.submit()">
        <option value=""><?= te('filter.all_domains') ?> (<?= array_sum(array_map('intval', array_column($domainList, 'n'))) ?>)</option>
        <?php foreach ($domainList as $dl): ?>
          <option value="<?= fresk_h((string)$dl['name']) ?>"<?= $fdom === $dl['name'] ? ' selected' : '' ?>><?= fresk_h((string)$dl['name']) ?> (<?= (int)$dl['n'] ?>)</option>
        <?php endforeach; ?>
      </select>
      <button class="btn btn-fresk-primary btn-sm" type="submit"><?= te('filter.apply') ?></button>
      <a class="btn btn-outline-secondary btn-sm<?= $filtered ? '' : ' disabled' ?>" href="<?= fresk_h($mailUrl(null)) ?>"<?= $filtered ? '' : ' aria-disabled="true" tabindex="-1"' ?> title="<?= te('filter.clear') ?>"><i class="bi bi-x-lg"></i><span class="d-none d-xl-inline ms-1"><?= te('filter.clear') ?></span></a>
      <span class="fresk-toolbar-count small text-muted text-nowrap ms-auto"><span class="fresk-count fw-semibold" data-count-for=".mail-filterable"><?= count($mailboxes) ?></span> <?= te('filter.mailboxes') ?></span>
    </form>
  </div>
</div>
<?php
// Webmail sin HTTPS (vhost solo HTTP): aviso + botón para emitir su certificado
$wmPending = array_values(array_filter(array_column($domainList, 'name'), static fn($dn) => ($fdom === null || $fdom === $dn) && fresk_webmail_https((string)$dn) === false));
if ($wmPending): ?>
<div class="alert alert-warning py-2 small mb-3">
  <i class="bi bi-shield-exclamation me-1"></i>Webmail sin certificado (solo HTTP; Chrome lo bloquea si el dominio usa HSTS). Requiere un registro A <code>webmail</code> → IP del servidor:
  <?php foreach ($wmPending as $dn): ?>
    <span class="ms-2 text-nowrap"><strong>webmail.<?= fresk_h((string)$dn) ?></strong> <?= fresk_webmail_ssl_cell((string)$dn) ?></span>
  <?php endforeach; ?>
</div>
<?php endif; ?>
<div class="card fresk-card">
  <div class="card-body">
    <h2 class="card-title">Buzones <span class="badge badge-status-none ms-1"><span data-count-for=".mail-filterable"><?= count($mailboxes) ?></span></span></h2>
    <?php if (!$mailboxes): ?>
      <p class="text-muted mb-0"><?= $filtered ? te('filter.none') : 'No hay buzones.' ?></p>
    <?php else: ?>
    <div class="table-responsive">
      <table class="table table-hover align-middle mb-0 mail-filterable">
        <thead><tr><th>Email</th><th>Cuota</th><th>Maildir</th><th>Estado</th><th>Acciones</th></tr></thead>
        <tbody>
        <?php foreach ($mailboxes as $m): ?>
          <tr data-filter-text="<?= fresk_h(strtolower($m['email'])) ?>">
            <td><strong><?= fresk_h($m['email']) ?></strong></td>
            <td><?= (int)$m['quota_mb'] ?> MB</td>
            <td class="text-muted small"><?= fresk_h($m['maildir']) ?></td>
            <td><?= fresk_status_badge((int)$m['active'] ? 'active' : 'off') ?>
              <?php if ((int)($m['vac_enabled'] ?? 0) === 1):
                $vacToday = (new DateTime('now', new DateTimeZone(getenv('PANEL_TZ') ?: 'Europe/Madrid')))->format('Y-m-d');
                $vacLive = ($m['vac_start'] === null || $m['vac_start'] <= $vacToday) && ($m['vac_end'] === null || $m['vac_end'] >= $vacToday); ?>
                <span class="badge <?= $vacLive ? 'text-bg-warning' : 'text-bg-secondary' ?> ms-1" title="<?= te($vacLive ? 'mail.vac_badge_live' : 'mail.vac_badge_sched') ?><?= $m['vac_start'] || $m['vac_end'] ? ' (' . fresk_h(($m['vac_start'] ?? '…') . ' → ' . ($m['vac_end'] ?? '…')) . ')' : '' ?>"><i class="bi bi-reply-fill"></i> <?= te('mail.vac_badge') ?></span>
              <?php endif; ?>
            </td>
            <td class="text-nowrap">
              <form method="post" class="d-inline">
                <?= fresk_csrf_field() ?>
                <input type="hidden" name="action" value="mail_passwd">
                <input type="hidden" name="email" value="<?= fresk_h($m['email']) ?>">
                <button type="submit" class="btn btn-sm btn-outline-secondary" onclick="return confirm('¿Regenerar contraseña?');">Nueva pass</button>
              </form>
              <button type="button" class="btn btn-sm btn-outline-danger"
                      data-bs-toggle="modal" data-bs-target="#modalDelMail"
                      data-email="<?= fresk_h($m['email']) ?>">Eliminar</button>
              <button type="button" class="btn btn-sm btn-outline-primary"
                      data-bs-toggle="modal" data-bs-target="#modalVacation"
                      data-email="<?= fresk_h($m['email']) ?>"
                      data-vac="<?= fresk_h((string)json_encode(['enabled' => (int)($m['vac_enabled'] ?? 0) === 1, 'subject' => (string)($m['vac_subject'] ?? ''), 'body' => (string)($m['vac_body'] ?? ''), 'html' => (int)($m['vac_html'] ?? 0) === 1, 'start' => (string)($m['vac_start'] ?? ''), 'end' => (string)($m['vac_end'] ?? '')], JSON_UNESCAPED_UNICODE)) ?>"
                      title="<?= te('mail.vac_btn_title') ?>"><i class="bi bi-reply"></i> <?= te('mail.vac_btn') ?></button>
              <?php $wm = $webmailUrl((string)$m['email']); if ($wm !== ''): ?>
              <a class="btn btn-sm btn-outline-success" href="<?= fresk_h($wm) ?>" target="_blank" rel="noopener" title="Abrir webmail (Roundcube) en una pestaña nueva"><i class="bi bi-envelope-open"></i> Webmail</a>
              <?php endif; ?>
            </td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table>
    </div>
    <?php endif; ?>
  </div>
</div>

<div class="row g-3">
  <div class="col-lg-6">
    <div class="card fresk-card h-100">
      <div class="card-body">
        <h2 class="card-title"><?= te('mail.alias') ?></h2>
        <p class="text-muted small"><?= te('mail.alias_help') ?></p>
        <form method="post" autocomplete="off" class="mb-3">
          <?= fresk_csrf_field() ?>
          <input type="hidden" name="action" value="alias_add">
          <div class="mb-2">
            <label class="form-label" for="alias_local"><?= te('mail.alias_src') ?></label>
            <div class="input-group">
              <input class="form-control" id="alias_local" name="local_part" type="text" placeholder="hola" required maxlength="64" pattern="[a-z0-9]([a-z0-9._+\-]*[a-z0-9])?" autocapitalize="none" spellcheck="false">
              <?= $domainPicker('alias_domain') ?>
            </div>
          </div>
          <div class="mb-2">
            <label class="form-label" for="alias_dst"><?= te('mail.alias_dst') ?></label>
            <input class="form-control" id="alias_dst" name="destination" type="text" placeholder="info@<?= fresk_h($phDomain) ?>" required>
          </div>
          <button type="submit" class="btn btn-fresk btn-sm"<?= $domainList ? '' : ' disabled' ?>><?= te('mail.alias_add') ?></button>
        </form>
        <?php if ($aliases): ?>
        <div class="table-responsive">
          <table class="table table-sm align-middle mb-0 mail-filterable-sub">
            <thead><tr><th>Origen</th><th>Destino</th><th></th></tr></thead>
            <tbody>
            <?php foreach ($aliases as $a): ?>
              <tr data-filter-text="<?= fresk_h(strtolower($a['source'] . ' ' . $a['destination'])) ?>">
                <td><?= fresk_h($a['source']) ?></td>
                <td><?= fresk_h($a['destination']) ?></td>
                <td>
                  <form method="post" onsubmit="return confirm('¿Eliminar alias?');">
                    <?= fresk_csrf_field() ?>
                    <input type="hidden" name="action" value="alias_del">
                    <input type="hidden" name="source" value="<?= fresk_h($a['source']) ?>">
                    <input type="hidden" name="destination" value="<?= fresk_h($a['destination']) ?>">
                    <button type="submit" class="btn btn-sm btn-fresk-danger">Del</button>
                  </form>
                </td>
              </tr>
            <?php endforeach; ?>
            </tbody>
          </table>
        </div>
        <?php endif; ?>
      </div>
    </div>
  </div>
  <div class="col-lg-6">
    <div class="card fresk-card h-100">
      <div class="card-body">
        <h2 class="card-title"><?= te('mail.forward') ?></h2>
        <p class="text-muted small"><?= te('mail.forward_help') ?></p>
        <form method="post" autocomplete="off" class="mb-3">
          <?= fresk_csrf_field() ?>
          <input type="hidden" name="action" value="forward_add">
          <div class="mb-2">
            <label class="form-label" for="fwd_mb"><?= te('mail.forward_mb') ?></label>
            <?php $fwdList = $fdom !== null ? array_values(array_filter($allMailboxes, static fn($e) => str_ends_with((string)$e, '@' . $fdom))) : $allMailboxes; ?>
            <?php if ($fwdList): ?>
            <select class="form-select" id="fwd_mb" name="mailbox" required>
              <?php foreach ($fwdList as $e): ?><option value="<?= fresk_h((string)$e) ?>"><?= fresk_h((string)$e) ?></option><?php endforeach; ?>
            </select>
            <?php else: ?>
            <p class="text-muted small mb-0"><?= te('mail.no_mailboxes') ?></p>
            <?php endif; ?>
          </div>
          <div class="mb-2">
            <label class="form-label" for="fwd_dst"><?= te('mail.forward_dst') ?></label>
            <input class="form-control" id="fwd_dst" name="destination" type="text" placeholder="otra@externo.com" required>
          </div>
          <button type="submit" class="btn btn-fresk btn-sm"<?= $fwdList ? '' : ' disabled' ?>><?= te('mail.forward_add') ?></button>
        </form>
        <?php if ($forwards): ?>
        <div class="table-responsive">
          <table class="table table-sm align-middle mb-0 mail-filterable-sub">
            <thead><tr><th>Buzón</th><th>Destino</th><th></th></tr></thead>
            <tbody>
            <?php foreach ($forwards as $f): ?>
              <tr data-filter-text="<?= fresk_h(strtolower($f['mailbox'] . ' ' . $f['destination'])) ?>">
                <td><?= fresk_h($f['mailbox']) ?></td>
                <td><?= fresk_h($f['destination']) ?></td>
                <td>
                  <form method="post" onsubmit="return confirm('¿Eliminar reenvío?');">
                    <?= fresk_csrf_field() ?>
                    <input type="hidden" name="action" value="forward_del">
                    <input type="hidden" name="mailbox" value="<?= fresk_h($f['mailbox']) ?>">
                    <input type="hidden" name="destination" value="<?= fresk_h($f['destination']) ?>">
                    <button type="submit" class="btn btn-sm btn-fresk-danger">Del</button>
                  </form>
                </td>
              </tr>
            <?php endforeach; ?>
            </tbody>
          </table>
        </div>
        <?php endif; ?>
      </div>
    </div>
  </div>
</div>


<div class="modal fade" id="modalAddMail" tabindex="-1" aria-labelledby="modalAddMailLabel" aria-hidden="true">
  <div class="modal-dialog">
    <form method="post" class="modal-content" autocomplete="off">
      <div class="modal-header">
        <h5 class="modal-title" id="modalAddMailLabel"><?= te('mail.add_title') ?></h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="<?= te('mail.cancel') ?>"></button>
      </div>
      <div class="modal-body">
        <?= fresk_csrf_field() ?>
        <input type="hidden" name="action" value="mail_add">
        <p class="text-muted small"><?= te('mail.add_help') ?></p>
        <?php if (!$domainList): ?>
          <div class="alert alert-warning small mb-0"><?= te('mail.no_domains') ?></div>
        <?php else: ?>
        <div class="mb-3">
          <label class="form-label" for="mb_local"><?= te('mail.local') ?></label>
          <div class="input-group">
            <input class="form-control" id="mb_local" name="local_part" type="text" placeholder="info" required maxlength="64"
                   pattern="[a-z0-9]([a-z0-9._+\-]*[a-z0-9])?" autocapitalize="none" spellcheck="false" autocomplete="off">
            <?= $domainPicker('mb_domain') ?>
          </div>
          <div class="form-text"><?= te('mail.local_help') ?></div>
        </div>
        <div class="mb-2">
          <label class="form-label" for="mb_pw"><?= te('mail.password') ?></label>
          <div class="input-group fresk-pw">
            <input class="form-control pw-new" id="mb_pw" name="password" type="password" required minlength="8" maxlength="128"
                   autocomplete="new-password" data-rules="mb_rules"
                   pattern="(?=.*\p{Lu})(?=.*\p{Ll})(?=.*\p{Nd})(?=.*[^\p{L}\p{N}\s]).{8,128}">
            <?= fresk_pw_toggle('mb_pw') ?>
            <button class="btn btn-outline-secondary" type="button" id="mb_gen"><i class="bi bi-magic me-1"></i><?= te('mail.generate') ?></button>
          </div>
        </div>
        <ul class="pw-rules" id="mb_rules" aria-live="polite">
          <li data-r="len"><?= te('users.rule_len') ?></li>
          <li data-r="upper"><?= te('users.rule_upper') ?></li>
          <li data-r="lower"><?= te('users.rule_lower') ?></li>
          <li data-r="digit"><?= te('users.rule_digit') ?></li>
          <li data-r="symbol"><?= te('users.rule_symbol') ?></li>
        </ul>
        <a class="small" data-bs-toggle="collapse" href="#mbAdvanced" role="button" aria-expanded="false" aria-controls="mbAdvanced"><i class="bi bi-sliders me-1"></i><?= te('mail.advanced') ?></a>
        <div class="collapse mt-2" id="mbAdvanced">
          <label class="form-label" for="quota"><?= te('mail.quota') ?></label>
          <input class="form-control" id="quota" name="quota" type="number" value="1024" min="1" max="1048576">
        </div>
        <?php endif; ?>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal"><?= te('mail.cancel') ?></button>
        <button type="submit" class="btn btn-fresk-primary"<?= $domainList ? '' : ' disabled' ?>><?= te('mail.add_btn') ?></button>
      </div>
    </form>
  </div>
</div>

<div class="modal fade" id="modalDelMail" tabindex="-1" aria-hidden="true">
  <div class="modal-dialog">
    <form method="post" class="modal-content" autocomplete="off">
      <div class="modal-header">
        <h5 class="modal-title text-danger">Eliminar buzón</h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
      </div>
      <div class="modal-body">
        <?= fresk_csrf_field() ?>
        <input type="hidden" name="action" value="mail_del">
        <input type="hidden" name="email" id="del_mail_hidden" value="">
        <p>Escribe <code id="del_mail_label"></code> para confirmar.</p>
        <input class="form-control mb-2" type="text" name="confirm" required>
        <div class="form-check">
          <input class="form-check-input" type="checkbox" name="keep_data" value="1" id="keep_maildir">
          <label class="form-check-label" for="keep_maildir">Conservar Maildir</label>
        </div>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Cancelar</button>
        <button type="submit" class="btn btn-fresk-danger">Confirmar baja</button>
      </div>
    </form>
  </div>
</div>
<div class="modal fade" id="modalVacation" tabindex="-1" aria-labelledby="modalVacationLabel" aria-hidden="true">
  <div class="modal-dialog modal-lg">
    <form method="post" class="modal-content" autocomplete="off">
      <div class="modal-header">
        <h5 class="modal-title" id="modalVacationLabel"><i class="bi bi-reply"></i> <?= te('mail.vac_title') ?> <code id="vac_label" class="ms-1"></code></h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="<?= te('mail.cancel') ?>"></button>
      </div>
      <div class="modal-body">
        <?= fresk_csrf_field() ?>
        <input type="hidden" name="action" value="mail_vacation">
        <input type="hidden" name="email" id="vac_email" value="">
        <div class="form-check form-switch mb-3">
          <input class="form-check-input" type="checkbox" role="switch" name="vac_enabled" value="1" id="vac_enabled">
          <label class="form-check-label fw-semibold" for="vac_enabled"><?= te('mail.vac_enabled') ?></label>
        </div>
        <div class="mb-3">
          <label class="form-label" for="vac_subject"><?= te('mail.vac_subject') ?></label>
          <input class="form-control" type="text" name="vac_subject" id="vac_subject" maxlength="200" placeholder="<?= te('mail.vac_subject_ph') ?>">
        </div>
        <div class="mb-2">
          <span class="form-label d-block"><?= te('mail.vac_format') ?></span>
          <div class="btn-group btn-group-sm" role="group">
            <input type="radio" class="btn-check" name="vac_format" id="vac_fmt_text" value="text" checked>
            <label class="btn btn-outline-secondary" for="vac_fmt_text"><?= te('mail.vac_fmt_text') ?></label>
            <input type="radio" class="btn-check" name="vac_format" id="vac_fmt_html" value="html">
            <label class="btn btn-outline-secondary" for="vac_fmt_html">HTML</label>
          </div>
        </div>
        <div class="mb-3">
          <label class="form-label" for="vac_body"><?= te('mail.vac_body') ?></label>
          <textarea class="form-control font-monospace" name="vac_body" id="vac_body" rows="8" maxlength="64000"></textarea>
          <div class="form-text" id="vac_html_help" hidden><?= te('mail.vac_html_help') ?></div>
        </div>
        <div class="row g-2 mb-2">
          <div class="col-sm-6">
            <label class="form-label" for="vac_start"><?= te('mail.vac_start') ?></label>
            <input class="form-control" type="date" name="vac_start" id="vac_start">
          </div>
          <div class="col-sm-6">
            <label class="form-label" for="vac_end"><?= te('mail.vac_end') ?></label>
            <input class="form-control" type="date" name="vac_end" id="vac_end">
          </div>
        </div>
        <p class="form-text mb-0"><i class="bi bi-info-circle"></i> <?= te('mail.vac_note') ?></p>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal"><?= te('mail.cancel') ?></button>
        <button type="submit" class="btn btn-fresk-primary"><?= te('mail.vac_save') ?></button>
      </div>
    </form>
  </div>
</div>
<script>
(function () {
  var inp = document.getElementById('mb_pw'); if (!inp) return;
  var rules = document.getElementById('mb_rules');
  var tests = {
    len: function (v) { return [...v].length >= 8; },
    upper: function (v) { return /\p{Lu}/u.test(v); },
    lower: function (v) { return /\p{Ll}/u.test(v); },
    digit: function (v) { return /\p{Nd}/u.test(v); },
    symbol: function (v) { return /[^\p{L}\p{N}\s]/u.test(v); }
  };
  function check() {
    Object.keys(tests).forEach(function (k) {
      var li = rules.querySelector('[data-r="' + k + '"]'); if (li) li.classList.toggle('ok', tests[k](inp.value));
    });
  }
  inp.addEventListener('input', check);
  function pick(set) { var a = new Uint32Array(1); crypto.getRandomValues(a); return set[a[0] % set.length]; }
  document.getElementById('mb_gen').addEventListener('click', function () {
    var U = 'ABCDEFGHJKLMNPQRSTUVWXYZ', L = 'abcdefghijkmnpqrstuvwxyz', D = '23456789', S = '!#%*+-=?@_';
    var all = U + L + D + S, out = [pick(U), pick(L), pick(D), pick(S)];
    while (out.length < 16) out.push(pick(all));
    for (var i = out.length - 1; i > 0; i--) { var a = new Uint32Array(1); crypto.getRandomValues(a); var j = a[0] % (i + 1); var t = out[i]; out[i] = out[j]; out[j] = t; }
    inp.value = out.join(''); inp.type = 'text';
    var tg = document.querySelector('[data-pw-toggle="mb_pw"]');
    if (tg) { tg.setAttribute('aria-pressed', 'true'); var ic = tg.querySelector('i'); if (ic) ic.className = 'bi bi-eye-slash'; }
    check(); inp.focus(); inp.select();
  });
  document.getElementById('mb_local').addEventListener('input', function () { this.value = this.value.toLowerCase(); });
})();
document.getElementById('modalDelMail').addEventListener('show.bs.modal', function (ev) {
  var e = (ev.relatedTarget && ev.relatedTarget.getAttribute('data-email')) || '';
  document.getElementById('del_mail_hidden').value = e;
  document.getElementById('del_mail_label').textContent = e;
});
(function () {
  var m = document.getElementById('modalVacation'); if (!m) return;
  var $ = function (id) { return document.getElementById(id); };
  function fmt() { $('vac_html_help').hidden = !$('vac_fmt_html').checked; }
  function req() { var on = $('vac_enabled').checked; $('vac_subject').required = on; $('vac_body').required = on; }
  $('vac_fmt_text').addEventListener('change', fmt); $('vac_fmt_html').addEventListener('change', fmt);
  $('vac_enabled').addEventListener('change', req);
  $('vac_start').addEventListener('change', function () { $('vac_end').min = this.value; });
  m.addEventListener('show.bs.modal', function (ev) {
    var b = ev.relatedTarget; if (!b) return;
    var v = {}; try { v = JSON.parse(b.getAttribute('data-vac') || '{}'); } catch (e) {}
    var e = b.getAttribute('data-email') || '';
    $('vac_email').value = e; $('vac_label').textContent = e;
    $('vac_enabled').checked = !!v.enabled;
    $('vac_subject').value = v.subject || '';
    $('vac_body').value = v.body || '';
    $(v.html ? 'vac_fmt_html' : 'vac_fmt_text').checked = true;
    $('vac_start').value = v.start || ''; $('vac_end').value = v.end || ''; $('vac_end').min = v.start || '';
    fmt(); req();
  });
})();
</script>
<?php fresk_layout_end(); ?>
