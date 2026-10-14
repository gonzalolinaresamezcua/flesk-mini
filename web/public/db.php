<?php
declare(strict_types=1);
require __DIR__ . '/auth.php';
fresk_require_login();
require __DIR__ . '/includes/layout.php';

$flash = '';
$flashErr = '';
$shownPassword = null;
$shownCreds = null;

function fresk_valid_db_name(string $n): ?string {
    $n = strtolower(trim($n));
    if ($n === '' || strlen($n) > 64) return null;
    if (!preg_match('/^db_[a-z0-9_]+$/', $n)) return null;
    return $n;
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    fresk_csrf_check();
    $action = (string)($_POST['action'] ?? '');

    if ($action === 'db_add') {
        $domain = fresk_valid_domain((string)($_POST['domain'] ?? ''));
        if ($domain === null) {
            $flashErr = 'Dominio inválido';
        } else {
            $r = fresk_cli(['db', 'add', $domain]);
            if ($r['code'] === 0) {
                $flash = 'Base de datos creada para ' . $domain;
                $shownPassword = $r['password'] ?? fresk_extract_password($r['stdout']);
                $shownCreds = $r['stdout'];
            } else {
                $flashErr = 'Error al crear BD (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
            }
        }
    } elseif ($action === 'db_passwd') {
        $dbName = fresk_valid_db_name((string)($_POST['db_name'] ?? ''));
        if ($dbName === null) {
            $flashErr = 'Nombre de BD inválido';
        } else {
            $r = fresk_cli(['db', 'passwd', $dbName]);
            if ($r['code'] === 0) {
                $flash = 'Contraseña regenerada: ' . $dbName;
                $shownPassword = $r['password'] ?? fresk_extract_password($r['stdout']);
            } else {
                $flashErr = 'Error passwd (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
            }
        }
    } elseif ($action === 'db_dump') {
        // Descargar SQL: volcado completo .sql.gz en streaming (flesk db dump vía sudo)
        $dbName = fresk_valid_db_name((string)($_POST['db_name'] ?? ''));
        if ($dbName === null || !fresk_db_registered($dbName)) {
            $flashErr = t('db.err_unregistered');
            fresk_audit('db.dump', (string)($_POST['db_name'] ?? ''), 'fail', 'no registrada');
        } else {
            $flashErr = fresk_db_stream_dump($dbName); // solo vuelve si el volcado no arrancó
        }
    } elseif ($action === 'db_open') {
        // Abrir en Adminer sin contraseña: token de un solo uso (60 s) ligado a esta sesión y a esta base
        $dbName = fresk_valid_db_name((string)($_POST['db_name'] ?? ''));
        if ($dbName === null || !fresk_db_registered($dbName)) {
            $flashErr = t('db.err_unregistered');
        } else {
            $tok = fresk_sgbd_issue_token($dbName);
            header('Cache-Control: no-store');
            header('Location: ' . fresk_base() . '/sgbd/?flesk_sso=' . $tok, true, 303);
            exit;
        }
    } elseif ($action === 'db_apps_refresh') {
        if (fresk_db_apps_refresh()) {
            $flash = t('db.apps_refreshed');
            fresk_audit('db.appinfo', null, 'ok', 'refresh');
        } else {
            $flashErr = t('db.apps_refresh_err');
        }
    } elseif ($action === 'db_del') {
        $dbName = fresk_valid_db_name((string)($_POST['db_name'] ?? ''));
        $confirm = strtolower(trim((string)($_POST['confirm'] ?? '')));
        if ($dbName === null) {
            $flashErr = 'Nombre de BD inválido';
        } elseif ($confirm !== $dbName) {
            $flashErr = 'Escribe el nombre exacto de la BD para confirmar la baja';
        } else {
            $r = fresk_cli(['db', 'del', $dbName, '--yes']);
            if ($r['code'] === 0) {
                $flash = 'Base eliminada: ' . $dbName;
            } else {
                $flashErr = 'Error al eliminar (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
            }
        }
    } else {
        $flashErr = 'Acción desconocida';
    }
}

$domains = fresk_pdo()->query("SELECT id, name FROM domains WHERE status='active' ORDER BY name")->fetchAll();
$filterDomain = fresk_valid_domain((string)($_GET['domain'] ?? '')) ?? '';
$sql = 'SELECT db.id, d.name AS domain, db.db_name, db.db_user, db.created_at
        FROM `databases` db
        JOIN domains d ON d.id = db.domain_id';
$params = [];
if ($filterDomain !== '') {
    $sql .= ' WHERE d.name = ?';
    $params[] = $filterDomain;
}
$sql .= ' ORDER BY d.name, db.db_name';
$stmt = fresk_pdo()->prepare($sql);
$stmt->execute($params);
$databases = $stmt->fetchAll();

// Aplicación/versión por base: caché db_app_cache (solo se detectan automáticamente las bases aún no vistas)
$appCache = [];
$loadAppCache = static function () use (&$appCache): void {
    $appCache = [];
    try {
        foreach (fresk_pdo()->query('SELECT * FROM db_app_cache') as $r) $appCache[(string)$r['db_name']] = $r;
    } catch (Throwable $e) {
        $appCache = [];
    }
};
$loadAppCache();
foreach ($databases as $row) {
    if (!isset($appCache[$row['db_name']])) { fresk_db_apps_refresh(); $loadAppCache(); break; }
}
/** Badge pequeño con el icono de la aplicación. */
function fresk_app_badge(array $c): string {
    $icons = ['wordpress' => ['bi-wordpress', '#21759b'], 'prestashop' => ['bi-cart3', '#df0067'], 'drupal' => ['bi-droplet-fill', '#0678be'],
        'dolibarr' => ['bi-building', '#263c5c'], 'suitecrm' => ['bi-people-fill', '#534d64'], 'espocrm' => ['bi-person-lines-fill', '#2c5ea8'],
        'kanboard' => ['bi-kanban', '#d14a00'], 'joomla' => ['bi-puzzle-fill', '#f44321'], 'nextcloud' => ['bi-cloud-fill', '#0082c9'],
        'moodle' => ['bi-mortarboard-fill', '#f98012'], 'matomo' => ['bi-graph-up', '#3152a0'], 'phpbb' => ['bi-chat-square-text-fill', '#105289'],
        'mediawiki' => ['bi-book-half', '#36c'], 'pkg' => ['bi-box-seam', '#6c757d']];
    [$ic, $col] = $icons[(string)$c['app']] ?? ['bi-app', '#6c757d'];
    return '<span class="badge rounded-pill text-white" style="background:' . $col . '"><i class="bi ' . $ic . ' me-1"></i>'
        . fresk_h((string)($c['app_name'] ?: $c['app'])) . '</span>';
}

fresk_layout_start(t('page.db'), 'db');
fresk_render_flashes($flash, $flashErr, $shownPassword, $shownCreds);
?>
<div class="d-flex justify-content-between align-items-center mb-3 flex-wrap gap-2">
  <h1 class="h4 mb-0"><?= te('page.db') ?></h1>
  <div class="d-flex gap-2">
  <a class="btn btn-outline-secondary btn-sm" href="<?= fresk_h(fresk_base() . '/sgbd/') ?>" target="_blank" rel="noopener noreferrer"><i class="bi bi-box-arrow-up-right"></i> <?= te('db.open_adminer') ?></a>
  <button type="button" class="btn btn-fresk-primary btn-sm" data-bs-toggle="modal" data-bs-target="#modalAddDb">
    <i class="bi bi-plus-lg"></i> Crear BD
  </button>
  </div>
</div>

<div class="card fresk-card">
  <div class="card-body">
    <div class="d-flex justify-content-between align-items-center flex-wrap gap-2 mb-2">
      <h2 class="card-title mb-0">Bases registradas</h2>
      <div class="d-flex align-items-center gap-2 flex-wrap">
      <form method="post" class="d-inline">
        <?= fresk_csrf_field() ?>
        <input type="hidden" name="action" value="db_apps_refresh">
        <button type="submit" class="btn btn-sm btn-outline-secondary" title="<?= te('db.apps_refresh_title') ?>"><i class="bi bi-arrow-clockwise"></i> <?= te('db.apps_refresh') ?></button>
      </form>
      <form method="get" class="d-flex align-items-center gap-2">
        <label class="form-label mb-0 small" for="filter">Filtrar</label>
        <select class="form-select form-select-sm" id="filter" name="domain" onchange="this.form.submit()" style="width:auto">
          <option value="">— todos —</option>
          <?php foreach ($domains as $d): ?>
            <option value="<?= fresk_h($d['name']) ?>" <?= $filterDomain === $d['name'] ? 'selected' : '' ?>>
              <?= fresk_h($d['name']) ?>
            </option>
          <?php endforeach; ?>
        </select>
      </form>
      </div>
    </div>
    <?php if (!$databases): ?>
      <p class="text-muted mb-0">No hay bases de datos de sitios.</p>
    <?php else: ?>
    <div class="table-responsive">
      <table class="table table-hover align-middle mb-0">
        <thead><tr><th>Dominio</th><th>Base</th><th>Usuario</th><th><?= te('db.col_app') ?></th><th><?= te('db.col_version') ?></th><th>Creada</th><th>Acciones</th></tr></thead>
        <tbody>
        <?php foreach ($databases as $row): ?>
          <tr>
            <td><?= fresk_h($row['domain']) ?></td>
            <td><strong><?= fresk_h($row['db_name']) ?></strong></td>
            <td><code><?= fresk_h($row['db_user']) ?></code></td>
            <?php $ac = $appCache[$row['db_name']] ?? null; ?>
            <td class="small" title="<?= $ac ? fresk_h(t('db.apps_source') . ': ' . ($ac['source'] ?: '—') . ' · ' . t('db.apps_detected') . ' ' . $ac['detected_at']) : '' ?>">
              <?php if ($ac && $ac['app']): ?>
                <?= fresk_app_badge($ac) ?>
                <?php if ($ac['note'] === 'empty'): ?><span class="badge text-bg-light border ms-1"><?= te('db.apps_empty') ?></span><?php endif; ?>
                <?php if ($ac['url']): ?>
                  <div><a class="text-muted text-decoration-none" href="<?= fresk_h($ac['url']) ?>" target="_blank" rel="noopener noreferrer"><i class="bi bi-link-45deg"></i><?= fresk_h(preg_replace('#^https?://#', '', (string)$ac['url'])) ?></a></div>
                <?php elseif ($ac['path']): ?>
                  <div class="text-muted"><code><?= fresk_h($ac['path']) ?></code></div>
                <?php endif; ?>
              <?php else: ?>
                <span class="text-muted">—</span>
              <?php endif; ?>
            </td>
            <td class="small"><?= ($ac && $ac['version']) ? fresk_h((string)$ac['version']) : '<span class="text-muted">—</span>' ?></td>
            <td class="text-muted small"><?= fresk_h((string)$row['created_at']) ?></td>
            <td class="text-nowrap">
              <form method="post" class="d-inline" target="_blank">
                <?= fresk_csrf_field() ?>
                <input type="hidden" name="action" value="db_open">
                <input type="hidden" name="db_name" value="<?= fresk_h($row['db_name']) ?>">
                <button type="submit" class="btn btn-sm btn-outline-success" title="<?= te('db.open_title') ?>"><i class="bi bi-box-arrow-up-right"></i> <?= te('db.open') ?></button>
              </form>
              <form method="post" class="d-inline">
                <?= fresk_csrf_field() ?>
                <input type="hidden" name="action" value="db_dump">
                <input type="hidden" name="db_name" value="<?= fresk_h($row['db_name']) ?>">
                <button type="submit" class="btn btn-sm btn-outline-primary" title="<?= te('db.dump_title') ?>"><i class="bi bi-download"></i> <?= te('db.dump') ?></button>
              </form>
              <form method="post" class="d-inline">
                <?= fresk_csrf_field() ?>
                <input type="hidden" name="action" value="db_passwd">
                <input type="hidden" name="db_name" value="<?= fresk_h($row['db_name']) ?>">
                <button type="submit" class="btn btn-sm btn-outline-secondary" onclick="return confirm('¿Regenerar contraseña?');">Nueva pass</button>
              </form>
              <button type="button" class="btn btn-sm btn-outline-danger"
                      data-bs-toggle="modal" data-bs-target="#modalDelDb"
                      data-db="<?= fresk_h($row['db_name']) ?>">Eliminar</button>
            </td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table>
    </div>
    <?php endif; ?>
  </div>
</div>

<div class="modal fade" id="modalAddDb" tabindex="-1" aria-hidden="true">
  <div class="modal-dialog">
    <form method="post" class="modal-content" autocomplete="off">
      <div class="modal-header">
        <h5 class="modal-title">Crear base de datos</h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
      </div>
      <div class="modal-body">
        <?= fresk_csrf_field() ?>
        <input type="hidden" name="action" value="db_add">
        <p class="text-muted small">MariaDB aislada: <code>db_&lt;dominio&gt;</code> + <code>user_&lt;dominio&gt;</code>. Credenciales solo una vez.</p>
        <label class="form-label" for="domain">Dominio</label>
        <select class="form-select" id="domain" name="domain" required>
          <option value="">—</option>
          <?php foreach ($domains as $d): ?>
            <option value="<?= fresk_h($d['name']) ?>"><?= fresk_h($d['name']) ?></option>
          <?php endforeach; ?>
        </select>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Cancelar</button>
        <button type="submit" class="btn btn-fresk-primary">Crear BD + usuario</button>
      </div>
    </form>
  </div>
</div>

<div class="modal fade" id="modalDelDb" tabindex="-1" aria-hidden="true">
  <div class="modal-dialog">
    <form method="post" class="modal-content" autocomplete="off">
      <div class="modal-header">
        <h5 class="modal-title text-danger">Eliminar base</h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
      </div>
      <div class="modal-body">
        <?= fresk_csrf_field() ?>
        <input type="hidden" name="action" value="db_del">
        <input type="hidden" name="db_name" id="del_db_hidden" value="">
        <p>Escribe <code id="del_db_label"></code> para confirmar.</p>
        <input class="form-control" type="text" name="confirm" required>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Cancelar</button>
        <button type="submit" class="btn btn-fresk-danger">Confirmar baja</button>
      </div>
    </form>
  </div>
</div>
<script>
document.getElementById('modalDelDb').addEventListener('show.bs.modal', function (ev) {
  var d = (ev.relatedTarget && ev.relatedTarget.getAttribute('data-db')) || '';
  document.getElementById('del_db_hidden').value = d;
  document.getElementById('del_db_label').textContent = d;
});
</script>
<?php fresk_layout_end(); ?>
