<?php
declare(strict_types=1);
require __DIR__ . '/auth.php';
fresk_require_login();
require __DIR__ . '/includes/layout.php';

$flash = '';
$flashErr = '';
$allowedTypes = ['A', 'AAAA', 'MX', 'CNAME', 'TXT', 'NS'];

function fresk_valid_dns_host(string $h): ?string {
    $h = strtolower(rtrim(trim($h), '.'));
    if ($h === '' || $h === '@') return '@';
    if (preg_match('/[;{}\r\n]/', $h)) return null;
    if (!preg_match('/^(\*|([a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?))(\.([a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?))*$/', $h)) {
        return null;
    }
    if (strlen($h) > 253) return null;
    return $h;
}

function fresk_valid_dns_value(string $type, string $v): ?string {
    // En TXT se permite ';' (SPF/DKIM/DMARC): el valor va entrecomillado y escapado en la zona
    if (preg_match($type === 'TXT' ? '/[{}\r\n]/' : '/[;{}\r\n]/', $v)) return null;
    if (strlen($v) > 1024) return null;
    switch ($type) {
        case 'A':
            if (!filter_var($v, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) return null;
            break;
        case 'AAAA':
            if (!filter_var($v, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) return null;
            break;
        case 'MX':
        case 'NS':
        case 'CNAME':
            if (trim($v) === '') return null;
            break;
        case 'TXT':
            break;
    }
    return $v;
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    fresk_csrf_check();
    $action = (string)($_POST['action'] ?? '');
    $domain = fresk_valid_domain((string)($_POST['domain'] ?? ''));

    if ($action === 'init' || $action === 'reset') {
        if ($domain === null) {
            $flashErr = 'Dominio inválido';
        } elseif ($action === 'reset' && (string)($_POST['confirm_domain'] ?? '') !== $domain) {
            $flashErr = t('dns.reset_mismatch');
        } else {
            $args = ['dns', 'init', $domain];
            if ($action === 'reset') $args[] = '--reset';
            $r = fresk_cli($args);
            if ($r['code'] === 0) {
                $flash = ($action === 'reset' ? t('dns.reset_done') : 'Zona inicializada: ') . ' ' . $domain;
                fresk_audit('dns.' . $action, $domain, 'ok');
            } else {
                $flashErr = 'Error dns init (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
            }
        }
    } elseif ($action === 'set') {
        $type = strtoupper(trim((string)($_POST['type'] ?? '')));
        $host = fresk_valid_dns_host((string)($_POST['host'] ?? '@'));
        $value = (string)($_POST['value'] ?? '');
        $ttl = (int)($_POST['ttl'] ?? 3600);
        if ($domain === null) {
            $flashErr = 'Dominio inválido';
        } elseif (!in_array($type, $allowedTypes, true)) {
            $flashErr = 'Tipo no permitido';
        } elseif ($host === null) {
            $flashErr = 'Host inválido';
        } else {
            $value = fresk_valid_dns_value($type, $value);
            if ($value === null) {
                $flashErr = 'Valor inválido para ' . $type;
            } else {
                $args = ['dns', 'set', $domain, $type, $host, $value];
                if ($ttl >= 60 && $ttl <= 86400) {
                    $args[] = '--ttl';
                    $args[] = (string)$ttl;
                }
                $r = fresk_cli($args);
                if ($r['code'] === 0) {
                    $flash = "Registro $type $host actualizado en $domain";
                } else {
                    $flashErr = 'Error dns set (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
                }
            }
        }
    } elseif ($action === 'del') {
        $type = strtoupper(trim((string)($_POST['type'] ?? '')));
        $host = fresk_valid_dns_host((string)($_POST['host'] ?? '@'));
        if ($domain === null || $host === null || !in_array($type, $allowedTypes, true)) {
            $flashErr = 'Datos de baja inválidos';
        } else {
            $r = fresk_cli(['dns', 'del', $domain, $type, $host]);
            if ($r['code'] === 0) {
                $flash = "Eliminado $type $host en $domain";
            } else {
                $flashErr = 'Error dns del (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
            }
        }
    } else {
        $flashErr = 'Acción desconocida';
    }
}

$domains = fresk_pdo()->query("SELECT id, name FROM domains WHERE status='active' ORDER BY name")->fetchAll();
$filterDomain = fresk_valid_domain((string)($_GET['domain'] ?? '')) ?? '';
$sql = 'SELECT r.id, d.name AS domain, r.type, r.host, r.value, r.ttl
        FROM dns_records r
        JOIN domains d ON d.id = r.domain_id';
$params = [];
if ($filterDomain !== '') {
    $sql .= ' WHERE d.name = ?';
    $params[] = $filterDomain;
}
$sql .= " ORDER BY d.name, FIELD(r.type,'NS','A','AAAA','MX','CNAME','TXT'), r.host, r.value";
$stmt = fresk_pdo()->prepare($sql);
$stmt->execute($params);
$records = $stmt->fetchAll();

$cfg = fresk_cfg();
$dnsPublic = strtolower((string)($cfg['DNS_PUBLIC'] ?? 'no'));
$publicIp = (string)($cfg['PUBLIC_IP'] ?? '');

fresk_layout_start('DNS', 'dns');
fresk_render_flashes($flash, $flashErr);
?>
<div class="d-flex justify-content-between align-items-center mb-3 flex-wrap gap-2">
  <h1 class="h4 mb-0"><?= te('page.dns') ?></h1>
</div>

<div class="card fresk-card">
  <div class="card-body">
    <p class="text-muted small mb-0">
      BIND9 autoritativo. Tipos: A, AAAA, MX, CNAME, TXT, NS.
      DNS público:
      <span class="badge <?= $dnsPublic === 'yes' ? 'badge-status-active' : 'badge-status-pending' ?>">DNS_PUBLIC=<?= fresk_h($dnsPublic) ?></span>
      <?php if ($dnsPublic !== 'yes'): ?>
        — puerto 53 cerrado en UFW; prueba con <code>dig @127.0.0.1</code>.
      <?php else: ?>
        — 53/tcp+udp abiertos.
      <?php endif; ?>
      <?php if ($publicIp !== ''): ?> IP: <code><?= fresk_h($publicIp) ?></code><?php endif; ?>
    </p>
  </div>
</div>

<div class="card fresk-card">
  <div class="card-body">
    <h2 class="card-title">Añadir / actualizar registro</h2>
    <form method="post" autocomplete="off">
      <?= fresk_csrf_field() ?>
      <input type="hidden" name="action" value="set">
      <div class="row g-2">
        <div class="col-md-3">
          <label class="form-label" for="domain">Dominio</label>
          <select class="form-select" id="domain" name="domain" required>
            <option value="">—</option>
            <?php foreach ($domains as $d): ?>
              <option value="<?= fresk_h($d['name']) ?>" <?= $filterDomain === $d['name'] ? 'selected' : '' ?>>
                <?= fresk_h($d['name']) ?>
              </option>
            <?php endforeach; ?>
          </select>
        </div>
        <div class="col-md-2">
          <label class="form-label" for="type">Tipo</label>
          <select class="form-select" id="type" name="type" required>
            <?php foreach ($allowedTypes as $t): ?>
              <option value="<?= $t ?>"><?= $t ?></option>
            <?php endforeach; ?>
          </select>
        </div>
        <div class="col-md-2">
          <label class="form-label" for="host">Nombre</label>
          <input class="form-control" id="host" name="host" type="text" value="@" required>
        </div>
        <div class="col-md-2">
          <label class="form-label" for="ttl">TTL</label>
          <input class="form-control" id="ttl" name="ttl" type="number" value="3600" min="60" max="86400">
        </div>
        <div class="col-md-3">
          <label class="form-label" for="value">Valor</label>
          <input class="form-control" id="value" name="value" type="text" placeholder="203.0.113.10" required>
        </div>
      </div>
      <p class="text-muted small mt-2 mb-2">MX: <code>10 mail.ejemplo.com</code></p>
      <button type="submit" class="btn btn-fresk-primary btn-sm">Guardar registro</button>
    </form>
    <hr>
    <div class="row g-2 align-items-end">
      <div class="col-md-5">
        <label class="form-label" for="reset_domain"><?= te('dns.reset_title') ?></label>
        <select class="form-select" id="reset_domain" required>
          <option value="">—</option>
          <?php foreach ($domains as $d): ?>
            <option value="<?= fresk_h($d['name']) ?>" <?= $filterDomain === $d['name'] ? 'selected' : '' ?>><?= fresk_h($d['name']) ?></option>
          <?php endforeach; ?>
        </select>
      </div>
      <div class="col-md-4">
        <button type="button" class="btn btn-outline-danger btn-sm" id="dnsResetBtn"><i class="bi bi-arrow-counterclockwise me-1"></i><?= te('dns.reset_btn') ?></button>
      </div>
      <p class="text-muted small mb-0"><?= te('dns.reset_help') ?></p>
    </div>
  </div>
</div>

<div class="card fresk-card">
  <div class="card-body">
    <div class="d-flex justify-content-between align-items-center flex-wrap gap-2 mb-2">
      <h2 class="card-title mb-0">Registros
        <?php if ($filterDomain !== ''): ?>
          · <?= fresk_h($filterDomain) ?>
          <a class="small text-muted ms-1" href="?">ver todos</a>
        <?php endif; ?>
      </h2>
      <form method="get" class="d-flex align-items-center gap-2">
        <label class="form-label mb-0 small" for="filter">Filtrar</label>
        <select class="form-select form-select-sm" id="filter" name="domain" onchange="this.form.submit()" style="width:auto">
          <option value="">Todos</option>
          <?php foreach ($domains as $d): ?>
            <option value="<?= fresk_h($d['name']) ?>" <?= $filterDomain === $d['name'] ? 'selected' : '' ?>>
              <?= fresk_h($d['name']) ?>
            </option>
          <?php endforeach; ?>
        </select>
      </form>
    </div>
    <?php if (!$records): ?>
      <p class="text-muted mb-0">Sin registros. Usa «dns init» o añade uno arriba.</p>
    <?php else: ?>
    <div class="table-responsive">
      <table class="table table-hover align-middle mb-0">
        <thead>
          <tr><th>Dominio</th><th>Tipo</th><th>Host</th><th>Valor</th><th>TTL</th><th></th></tr>
        </thead>
        <tbody>
        <?php foreach ($records as $r): ?>
          <tr>
            <td><a href="?domain=<?= urlencode($r['domain']) ?>"><?= fresk_h($r['domain']) ?></a></td>
            <td><strong><?= fresk_h($r['type']) ?></strong></td>
            <td><?= fresk_h($r['host']) ?></td>
            <td><code><?= fresk_h($r['value']) ?></code></td>
            <td><?= (int)$r['ttl'] ?></td>
            <td>
              <form method="post" class="d-inline" onsubmit="return confirm('¿Eliminar este registro?');">
                <?= fresk_csrf_field() ?>
                <input type="hidden" name="action" value="del">
                <input type="hidden" name="domain" value="<?= fresk_h($r['domain']) ?>">
                <input type="hidden" name="type" value="<?= fresk_h($r['type']) ?>">
                <input type="hidden" name="host" value="<?= fresk_h($r['host']) ?>">
                <button type="submit" class="btn btn-sm btn-fresk-danger">Eliminar</button>
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

<div class="modal fade" id="dnsResetModal" tabindex="-1" aria-labelledby="dnsResetLabel" aria-hidden="true">
  <div class="modal-dialog">
    <form method="post" class="modal-content" autocomplete="off">
      <?= fresk_csrf_field() ?>
      <input type="hidden" name="action" value="reset">
      <input type="hidden" name="domain" id="dnsResetDomain">
      <div class="modal-header">
        <h5 class="modal-title" id="dnsResetLabel"><i class="bi bi-exclamation-triangle text-danger me-2"></i><?= te('dns.reset_title') ?></h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="<?= te('common.close') ?>"></button>
      </div>
      <div class="modal-body">
        <p><?= te('dns.reset_warn') ?></p>
        <ul class="small text-muted mb-3">
          <li>NS ns1/ns2 + glue · A/AAAA: @ www webmail mail smtp pop imap ftp</li>
          <li>MX 10 mail · SPF <code>include:_spf.mail.&lt;dominio&gt;</code> · DKIM <code>default._domainkey</code> · DMARC</li>
        </ul>
        <label class="form-label" for="dnsResetConfirm"><?= te('dns.reset_type') ?> <strong id="dnsResetName"></strong></label>
        <input class="form-control" id="dnsResetConfirm" name="confirm_domain" required spellcheck="false">
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal"><?= te('common.cancel') ?></button>
        <button type="submit" class="btn btn-fresk-danger" id="dnsResetGo" disabled><?= te('dns.reset_btn') ?></button>
      </div>
    </form>
  </div>
</div>
<script>
(function () {
  var sel = document.getElementById('reset_domain'), btn = document.getElementById('dnsResetBtn');
  var inp = document.getElementById('dnsResetConfirm'), go = document.getElementById('dnsResetGo');
  btn.addEventListener('click', function () {
    if (!sel.value) { sel.focus(); return; }
    document.getElementById('dnsResetDomain').value = sel.value;
    document.getElementById('dnsResetName').textContent = sel.value;
    inp.value = ''; go.disabled = true;
    bootstrap.Modal.getOrCreateInstance(document.getElementById('dnsResetModal')).show();
  });
  inp.addEventListener('input', function () { go.disabled = inp.value.trim() !== sel.value; });
})();
</script>
<?php fresk_layout_end(); ?>
