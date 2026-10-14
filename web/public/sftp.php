<?php
declare(strict_types=1);
require __DIR__ . '/auth.php';
fresk_require_login();
require __DIR__ . '/includes/layout.php';
require_once __DIR__ . '/includes/sftphost.php';

$flash = '';
$flashErr = '';
$shownPassword = null;

function fresk_valid_sftp_user(string $u): ?string {
    $u = strtolower(trim($u));
    if ($u === '' || strlen($u) > 32) return null;
    if (!preg_match('/^[a-z_][a-z0-9_-]{0,31}$/', $u)) return null;
    $reserved = ['root','www-data','flesk','ubuntu','fresk','vmail','nobody','daemon','mysql','nginx','sshd','postfix','dovecot'];
    if (in_array($u, $reserved, true)) return null;
    return $u;
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    fresk_csrf_check();
    $action = (string)($_POST['action'] ?? '');

    if ($action === 'sftp_add') {
        $domain = fresk_valid_domain((string)($_POST['domain'] ?? ''));
        $username = fresk_valid_sftp_user((string)($_POST['username'] ?? ''));
        if ($domain === null) {
            $flashErr = 'Dominio inválido';
        } elseif ($username === null) {
            $flashErr = 'Usuario inválido (a-z, 0-9, _, -; máx. 32; no reservados)';
        } else {
            $r = fresk_cli(['sftp', 'add', $domain, $username]);
            if ($r['code'] === 0) {
                $flash = 'Usuario SFTP creado: ' . $username . ' → ' . $domain;
                $shownPassword = $r['password'] ?? fresk_extract_password($r['stdout']);
            } else {
                $flashErr = 'Error al crear SFTP (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
            }
        }
    } elseif ($action === 'sftp_passwd') {
        $username = fresk_valid_sftp_user((string)($_POST['username'] ?? ''));
        if ($username === null) {
            $flashErr = 'Usuario inválido';
        } else {
            $r = fresk_cli(['sftp', 'passwd', $username]);
            if ($r['code'] === 0) {
                $flash = 'Contraseña regenerada: ' . $username;
                $shownPassword = $r['password'] ?? fresk_extract_password($r['stdout']);
            } else {
                $flashErr = 'Error passwd (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
            }
        }
    } elseif ($action === 'sftp_del') {
        $username = fresk_valid_sftp_user((string)($_POST['username'] ?? ''));
        $confirm = strtolower(trim((string)($_POST['confirm'] ?? '')));
        if ($username === null) {
            $flashErr = 'Usuario inválido';
        } elseif ($confirm !== $username) {
            $flashErr = 'Escribe el nombre exacto del usuario para confirmar la baja';
        } else {
            $r = fresk_cli(['sftp', 'del', $username, '--yes']);
            if ($r['code'] === 0) {
                $flash = 'Usuario SFTP eliminado: ' . $username;
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
$sql = 'SELECT s.id, d.name AS domain, s.username, s.system_user, s.created_at
        FROM sftp_users s
        JOIN domains d ON d.id = s.domain_id';
$params = [];
if ($filterDomain !== '') {
    $sql .= ' WHERE d.name = ?';
    $params[] = $filterDomain;
}
$sql .= ' ORDER BY d.name, s.username';
$stmt = fresk_pdo()->prepare($sql);
$stmt->execute($params);
$sftpUsers = $stmt->fetchAll();

fresk_layout_start('SFTP', 'sftp');
fresk_render_flashes($flash, $flashErr, $shownPassword);
?>
<div class="d-flex justify-content-between align-items-center mb-3 flex-wrap gap-2">
  <h1 class="h4 mb-0"><?= te('page.sftp') ?></h1>
  <button type="button" class="btn btn-fresk-primary btn-sm" data-bs-toggle="modal" data-bs-target="#modalAddSftp">
    <i class="bi bi-plus-lg"></i> Crear usuario
  </button>
</div>

<div class="card fresk-card">
  <div class="card-body">
    <div class="d-flex justify-content-between align-items-center flex-wrap gap-2 mb-2">
      <h2 class="card-title mb-0">Usuarios SFTP</h2>
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
    <?php if (!$sftpUsers): ?>
      <p class="text-muted mb-0">No hay usuarios SFTP.</p>
    <?php else: ?>
    <div class="table-responsive">
      <table class="table table-hover align-middle mb-0">
        <thead><tr><th>Dominio</th><th>Servidor (SFTP, puerto 22)</th><th>Usuario</th><th>Sistema</th><th>Creado</th><th>Acciones</th></tr></thead>
        <tbody>
        <?php foreach ($sftpUsers as $row): ?>
          <tr>
            <td><?= fresk_h($row['domain']) ?></td>
            <?php $sh = fresk_sftp_host((string)$row['domain']); ?>
            <td><code><?= fresk_h($sh['host']) ?></code><?php if ($sh['note'] !== ''): ?> <i class="bi bi-info-circle text-muted" title="<?= fresk_h($sh['note']) ?>"></i><?php endif; ?></td>
            <td><strong><?= fresk_h($row['username']) ?></strong></td>
            <td><code><?= fresk_h($row['system_user']) ?></code></td>
            <td class="text-muted small"><?= fresk_h((string)$row['created_at']) ?></td>
            <td class="text-nowrap">
              <form method="post" class="d-inline">
                <?= fresk_csrf_field() ?>
                <input type="hidden" name="action" value="sftp_passwd">
                <input type="hidden" name="username" value="<?= fresk_h($row['username']) ?>">
                <button type="submit" class="btn btn-sm btn-outline-secondary" onclick="return confirm('¿Regenerar contraseña?');">Nueva pass</button>
              </form>
              <button type="button" class="btn btn-sm btn-outline-danger"
                      data-bs-toggle="modal" data-bs-target="#modalDelSftp"
                      data-user="<?= fresk_h($row['username']) ?>">Eliminar</button>
            </td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table>
    </div>
    <?php endif; ?>
  </div>
</div>

<div class="modal fade" id="modalAddSftp" tabindex="-1" aria-hidden="true">
  <div class="modal-dialog">
    <form method="post" class="modal-content" autocomplete="off">
      <div class="modal-header">
        <h5 class="modal-title">Crear usuario SFTP</h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
      </div>
      <div class="modal-body">
        <?= fresk_csrf_field() ?>
        <input type="hidden" name="action" value="sftp_add">
        <p class="text-muted small">Chroot en <code>/var/www/vhosts/&lt;dominio&gt;</code>. Solo escribe en <code>httpdocs</code> (sin shell).</p>
        <div class="mb-3">
          <label class="form-label" for="domain">Dominio</label>
          <select class="form-select" id="domain" name="domain" required>
            <option value="">—</option>
            <?php foreach ($domains as $d): ?>
              <option value="<?= fresk_h($d['name']) ?>"><?= fresk_h($d['name']) ?></option>
            <?php endforeach; ?>
          </select>
        </div>
        <div class="mb-0">
          <label class="form-label" for="username">Usuario</label>
          <input class="form-control" type="text" id="username" name="username" required maxlength="32"
                 pattern="[a-z_][a-z0-9_-]{0,31}" placeholder="sftpuser1" autocomplete="off">
        </div>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Cancelar</button>
        <button type="submit" class="btn btn-fresk-primary">Crear usuario SFTP</button>
      </div>
    </form>
  </div>
</div>

<div class="modal fade" id="modalDelSftp" tabindex="-1" aria-hidden="true">
  <div class="modal-dialog">
    <form method="post" class="modal-content" autocomplete="off">
      <div class="modal-header">
        <h5 class="modal-title text-danger">Eliminar usuario SFTP</h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
      </div>
      <div class="modal-body">
        <?= fresk_csrf_field() ?>
        <input type="hidden" name="action" value="sftp_del">
        <input type="hidden" name="username" id="del_sftp_hidden" value="">
        <p>Escribe <code id="del_sftp_label"></code> para confirmar.</p>
        <input class="form-control" type="text" name="confirm" required autocomplete="off">
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Cancelar</button>
        <button type="submit" class="btn btn-fresk-danger">Confirmar baja</button>
      </div>
    </form>
  </div>
</div>
<script>
document.getElementById('modalDelSftp').addEventListener('show.bs.modal', function (ev) {
  var u = (ev.relatedTarget && ev.relatedTarget.getAttribute('data-user')) || '';
  document.getElementById('del_sftp_hidden').value = u;
  document.getElementById('del_sftp_label').textContent = u;
});
</script>
<?php fresk_layout_end(); ?>
