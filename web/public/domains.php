<?php
declare(strict_types=1);
require __DIR__ . '/auth.php';
fresk_require_login();
require __DIR__ . '/includes/layout.php';

$flash = '';
$flashErr = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    fresk_csrf_check();
    $action = (string)($_POST['action'] ?? '');
    $domain = fresk_valid_domain((string)($_POST['domain'] ?? ''));
    if ($domain === null && $action !== '') {
        $flashErr = 'Dominio inválido';
    } elseif ($action === 'add') {
        $r = fresk_cli(['domain', 'add', $domain]);
        if ($r['code'] === 0) {
            $flash = 'Dominio añadido: ' . $domain;
        } else {
            $flashErr = 'Error al añadir (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
        }
    } elseif ($action === 'remove') {
        $confirm = strtolower(trim((string)($_POST['confirm'] ?? '')));
        if ($confirm !== $domain) {
            $flashErr = 'Escribe el nombre del dominio para confirmar la baja';
        } else {
            $args = ['domain', 'remove', $domain];
            if (!empty($_POST['keep_data'])) $args[] = '--keep-data';
            $r = fresk_cli($args);
            if ($r['code'] === 0) {
                $flash = 'Dominio eliminado: ' . $domain;
            } else {
                $flashErr = 'Error al eliminar (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
            }
        }
    } elseif ($action === 'ssl_issue') {
        $r = fresk_cli(['ssl', 'issue', $domain]);
        if ($r['code'] === 0) {
            $flash = 'SSL emitido/activo: ' . $domain;
        } else {
            $flashErr = 'SSL (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
        }
    } else {
        $flashErr = 'Acción desconocida';
    }
}

// Filtros (GET): q = texto en nombre, st = active|other, ssl = active|none|error
$fq = trim((string)($_GET['q'] ?? ''));
$fq = mb_substr(preg_replace('/[^a-z0-9.\-]/', '', strtolower($fq)) ?? '', 0, 253);
$fst = in_array($_GET['st'] ?? '', ['active', 'other'], true) ? (string)$_GET['st'] : '';
$fssl = in_array($_GET['ssl'] ?? '', ['active', 'none', 'error'], true) ? (string)$_GET['ssl'] : '';
$where = [];
$params = [];
if ($fq !== '') { $where[] = 'd.name LIKE ?'; $params[] = '%' . addcslashes($fq, '%_\\') . '%'; }
if ($fst === 'active') $where[] = "d.status = 'active'";
if ($fst === 'other') $where[] = "d.status <> 'active'";
if ($fssl === 'active') $where[] = "c.status = 'active'";
if ($fssl === 'none') $where[] = 'c.id IS NULL';
if ($fssl === 'error') $where[] = "c.status IN ('error','expired','pending')";
$stmt = fresk_pdo()->prepare(
    'SELECT d.id, d.name, d.status, d.php_version, d.ipv4, d.docroot, d.created_at,
            c.status AS ssl_status, c.not_after AS ssl_not_after, c.issuer AS ssl_issuer
     FROM domains d
     LEFT JOIN ssl_certs c ON c.domain_id = d.id'
    . ($where ? ' WHERE ' . implode(' AND ', $where) : '') .
    ' ORDER BY d.name'
);
$stmt->execute($params);
$domains = $stmt->fetchAll();
$totalDomains = (int)fresk_pdo()->query('SELECT COUNT(*) FROM domains')->fetchColumn();
$filtered = ($fq !== '' || $fst !== '' || $fssl !== '');

fresk_layout_start('Dominios', 'domains');
fresk_render_flashes($flash, $flashErr);
?>
<div class="d-flex justify-content-between align-items-center mb-3 flex-wrap gap-2">
  <h1 class="h4 mb-0"><?= te('page.domains') ?></h1>
  <button type="button" class="btn btn-fresk-primary btn-sm" data-bs-toggle="modal" data-bs-target="#modalAddDomain">
    <i class="bi bi-plus-lg"></i> Añadir dominio
  </button>
</div>

<div class="card fresk-card fresk-filter-bar mb-3">
  <div class="card-body py-2">
    <form method="get" role="search" class="fresk-toolbar d-flex flex-wrap flex-md-nowrap align-items-center gap-2" aria-label="<?= te('filter.title') ?>">
      <div class="input-group input-group-sm fresk-toolbar-search flex-grow-1">
        <span class="input-group-text"><i class="bi bi-search"></i></span>
        <input class="form-control" type="search" id="fq" name="q" value="<?= fresk_h($fq) ?>" placeholder="<?= te('filter.q_domain') ?>" aria-label="<?= te('filter.q_domain') ?>" autocomplete="off" data-live-filter="#domTable">
      </div>
      <select class="form-select form-select-sm w-auto fresk-toolbar-select" id="fst" name="st" aria-label="<?= te('filter.status') ?>" onchange="this.form.submit()">
        <option value=""><?= te('filter.status') ?>: <?= te('filter.all') ?></option>
        <option value="active"<?= $fst === 'active' ? ' selected' : '' ?>><?= te('filter.status') ?>: <?= te('filter.active') ?></option>
        <option value="other"<?= $fst === 'other' ? ' selected' : '' ?>><?= te('filter.status') ?>: <?= te('filter.other') ?></option>
      </select>
      <select class="form-select form-select-sm w-auto fresk-toolbar-select" id="fssl" name="ssl" aria-label="<?= te('filter.ssl') ?>" onchange="this.form.submit()">
        <option value=""><?= te('filter.ssl') ?>: <?= te('filter.all') ?></option>
        <option value="active"<?= $fssl === 'active' ? ' selected' : '' ?>><?= te('filter.ssl') ?>: <?= te('filter.ssl_active') ?></option>
        <option value="none"<?= $fssl === 'none' ? ' selected' : '' ?>><?= te('filter.ssl') ?>: <?= te('filter.ssl_none') ?></option>
        <option value="error"<?= $fssl === 'error' ? ' selected' : '' ?>><?= te('filter.ssl') ?>: <?= te('filter.ssl_error') ?></option>
      </select>
      <button class="btn btn-fresk-primary btn-sm" type="submit"><?= te('filter.apply') ?></button>
      <a class="btn btn-outline-secondary btn-sm<?= $filtered ? '' : ' disabled' ?>" href="<?= fresk_h(fresk_base() . '/domains.php') ?>"<?= $filtered ? '' : ' aria-disabled="true" tabindex="-1"' ?> title="<?= te('filter.clear') ?>"><i class="bi bi-x-lg"></i><span class="d-none d-xl-inline ms-1"><?= te('filter.clear') ?></span></a>
      <span class="fresk-toolbar-count small text-muted text-nowrap ms-auto"><span class="fresk-count fw-semibold" data-count-for="#domTable"><?= count($domains) ?></span> / <?= $totalDomains ?></span>
    </form>
  </div>
</div>

<div class="card fresk-card">
  <div class="card-body">
    <h2 class="card-title">Listado <span class="badge badge-status-none ms-1"><?= te('filter.results', count($domains)) ?></span></h2>
    <?php if (!$domains): ?>
      <p class="text-muted mb-0"><?= $filtered ? te('filter.none') : 'No hay dominios todavía.' ?></p>
    <?php else: ?>
    <div class="table-responsive">
      <table class="table table-hover align-middle mb-0" id="domTable">
        <thead>
          <tr><th>ID</th><th>Nombre</th><th>Estado</th><th>SSL</th><th>PHP</th><th>Docroot</th><th>Acciones</th></tr>
        </thead>
        <tbody>
        <?php foreach ($domains as $d):
          $sslStatus = $d['ssl_status'] ?? null;
          $sslLabel = $sslStatus ?: 'sin cert';
          if ($sslStatus === 'active' && !empty($d['ssl_not_after'])) {
              $sslLabel .= ' · ' . $d['ssl_not_after'];
          }
          $sslClass = match ($sslStatus) {
              'active' => 'badge-status-active',
              'pending' => 'badge-status-pending',
              'error', 'expired' => 'badge-status-error',
              default => 'badge-status-none',
          };
        ?>
          <tr data-filter-text="<?= fresk_h(strtolower($d['name'])) ?>">
            <td><?= (int)$d['id'] ?></td>
            <?php $siteUrl = ($sslStatus === 'active' ? 'https://' : 'http://') . $d['name'] . '/'; ?>
            <td>
              <a href="<?= fresk_h($siteUrl) ?>" target="_blank" rel="noopener noreferrer" class="fw-semibold text-decoration-none"><?= fresk_h($d['name']) ?></a>
              <a href="<?= fresk_h($siteUrl) ?>" target="_blank" rel="noopener noreferrer" class="ms-1 text-secondary" title="Abrir <?= fresk_h($d['name']) ?> en pestaña nueva" aria-label="Abrir en pestaña nueva"><i class="bi bi-box-arrow-up-right"></i></a>
            </td>
            <td><?= fresk_status_badge($d['status']) ?></td>
            <td><span class="badge <?= $sslClass ?>"><?= fresk_h($sslLabel) ?></span></td>
            <td><?= fresk_h($d['php_version']) ?></td>
            <td class="text-muted small"><?= fresk_h($d['docroot']) ?></td>
            <td class="text-nowrap">
              <?php if ($sslStatus !== 'active'): ?>
              <form method="post" class="d-inline" onsubmit="return confirm('¿Emitir SSL Let\\'s Encrypt para <?= fresk_h($d['name']) ?>?');">
                <?= fresk_csrf_field() ?>
                <input type="hidden" name="action" value="ssl_issue">
                <input type="hidden" name="domain" value="<?= fresk_h($d['name']) ?>">
                <button type="submit" class="btn btn-sm btn-fresk-success">Emitir SSL</button>
              </form>
              <?php else: ?>
              <span class="text-muted small me-2">HTTPS activo</span>
              <?php endif; ?>
              <button type="button" class="btn btn-sm btn-outline-danger"
                      data-bs-toggle="modal" data-bs-target="#modalDelDomain"
                      data-domain="<?= fresk_h($d['name']) ?>">Eliminar</button>
            </td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table>
    </div>
    <?php endif; ?>
  </div>
</div>

<!-- Modal alta -->
<div class="modal fade" id="modalAddDomain" tabindex="-1" aria-labelledby="modalAddDomainLabel" aria-hidden="true">
  <div class="modal-dialog">
    <form method="post" class="modal-content" autocomplete="off">
      <div class="modal-header">
        <h5 class="modal-title" id="modalAddDomainLabel">Añadir dominio</h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Cerrar"></button>
      </div>
      <div class="modal-body">
        <?= fresk_csrf_field() ?>
        <input type="hidden" name="action" value="add">
        <p class="text-muted small">Crea httpdocs, logs, vhost HTTP y fila en la base. SSL requiere registro A → IP del servidor.</p>
        <label class="form-label" for="domain_add">Nombre del dominio</label>
        <input class="form-control" id="domain_add" name="domain" type="text" placeholder="ejemplo.com" required pattern="[A-Za-z0-9.-]+">
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Cancelar</button>
        <button type="submit" class="btn btn-fresk-primary">Añadir</button>
      </div>
    </form>
  </div>
</div>

<!-- Modal baja -->
<div class="modal fade" id="modalDelDomain" tabindex="-1" aria-hidden="true">
  <div class="modal-dialog">
    <form method="post" class="modal-content" autocomplete="off">
      <div class="modal-header">
        <h5 class="modal-title text-danger">Eliminar dominio</h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Cerrar"></button>
      </div>
      <div class="modal-body">
        <?= fresk_csrf_field() ?>
        <input type="hidden" name="action" value="remove">
        <input type="hidden" name="domain" id="del_domain_hidden" value="">
        <p>Escribe <code id="del_domain_label"></code> para confirmar la baja.</p>
        <input class="form-control mb-2" type="text" name="confirm" id="del_domain_confirm" required>
        <div class="form-check">
          <input class="form-check-input" type="checkbox" name="keep_data" value="1" id="keep_data">
          <label class="form-check-label" for="keep_data">Conservar archivos (--keep-data)</label>
        </div>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Cancelar</button>
        <button type="submit" class="btn btn-fresk-danger">Confirmar baja</button>
      </div>
    </form>
  </div>
</div>
<script>
document.getElementById('modalDelDomain').addEventListener('show.bs.modal', function (ev) {
  var btn = ev.relatedTarget;
  var d = btn.getAttribute('data-domain') || '';
  document.getElementById('del_domain_hidden').value = d;
  document.getElementById('del_domain_label').textContent = d;
  document.getElementById('del_domain_confirm').value = '';
});
</script>

<?php fresk_layout_end(); ?>
