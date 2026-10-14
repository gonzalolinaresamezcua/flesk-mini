<?php
declare(strict_types=1);
require __DIR__ . '/auth.php';
fresk_require_login();
require __DIR__ . '/includes/layout.php';
require __DIR__ . '/includes/webmail_ssl.php';

$flash = '';
$flashErr = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    fresk_csrf_check();
    $action = (string)($_POST['action'] ?? '');
    $domain = fresk_valid_domain((string)($_POST['domain'] ?? ''));
    if ($domain === null) {
        $flashErr = 'Dominio inválido';
    } elseif ($action === 'issue') {
        $r = fresk_cli(['ssl', 'issue', $domain]);
        if ($r['code'] === 0) {
            $flash = 'SSL emitido/activo: ' . $domain;
        } else {
            $flashErr = 'SSL issue (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
        }
    } elseif ($action === 'webmail_ssl') {
        [$flash, $flashErr] = fresk_webmail_ssl_issue($domain);
    } elseif ($action === 'status') {
        $r = fresk_cli(['ssl', 'status', $domain]);
        if ($r['code'] === 0) {
            $flash = 'Estado SSL ' . $domain . ': ' . trim($r['stdout']);
        } else {
            $flashErr = 'SSL status (' . $r['code'] . '): ' . trim($r['stderr'] . ' ' . $r['stdout']);
        }
    } else {
        $flashErr = 'Acción desconocida';
    }
}

$rows = fresk_pdo()->query(
    "SELECT d.id, d.name, d.status AS domain_status,
            c.status AS ssl_status, c.not_after, c.issuer, c.path_fullchain, c.method, c.names, c.note
     FROM domains d
     LEFT JOIN ssl_certs c ON c.domain_id = d.id
     ORDER BY d.name"
)->fetchAll();

fresk_layout_start('SSL', 'ssl');
fresk_render_flashes($flash, $flashErr);
?>
<div class="d-flex justify-content-between align-items-center mb-3 flex-wrap gap-2">
  <h1 class="h4 mb-0">SSL / Let's Encrypt</h1>
</div>

<div class="card fresk-card">
  <div class="card-body">
    <p class="text-muted small">Let's Encrypt. <strong>DNS-01</strong> con comodín (<code>*.dominio</code>) cuando los NS del dominio apuntan a este servidor y el DNS es público; si no, <strong>HTTP-01</strong> con SAN: el dominio más <code>www</code>, <code>webmail</code> y <code>mail</code> que ya resuelvan a la IP del servidor. El certificado también se usa en webmail.&lt;dominio&gt; (si <code>webmail</code> no está en él, la columna Webmail emite un certificado propio para <code>webmail.&lt;dominio&gt;</code> cuando su registro A apunta aquí) y, por SNI, en Postfix/Dovecot (mail./smtp./imap./pop.).</p>
    <div class="table-responsive">
      <table class="table table-hover align-middle mb-0">
        <thead>
          <tr><th>Dominio</th><th>Estado dominio</th><th>SSL</th><th><?= te('ssl.method') ?></th><th>Caduca</th><th>Emisor</th><th><?= te('ssl.webmail') ?></th><th>Acciones</th></tr>
        </thead>
        <tbody>
        <?php if (!$rows): ?>
          <tr><td colspan="8" class="text-muted">No hay dominios.</td></tr>
        <?php else: foreach ($rows as $r):
          $ssl = $r['ssl_status'] ?? null;
          $sslClass = match ($ssl) {
              'active' => 'badge-status-active',
              'pending' => 'badge-status-pending',
              'error', 'expired' => 'badge-status-error',
              default => 'badge-status-none',
          };
          $sslLabel = $ssl ?: 'sin cert';
        ?>
          <tr>
            <td><strong><?= fresk_h($r['name']) ?></strong>
              <?php if (!empty($r['names']) && $ssl === 'active'): ?><div class="small text-muted"><?= fresk_h(str_replace(',', ', ', (string)$r['names'])) ?></div><?php endif; ?>
              <?php if (!empty($r['note']) && $r['note'] !== 'dns-mismatch'): ?><div class="small text-warning-emphasis"><i class="bi bi-exclamation-triangle me-1"></i><?= fresk_h((string)$r['note']) ?></div><?php endif; ?>
            </td>
            <td><?= fresk_status_badge($r['domain_status']) ?></td>
            <td><span class="badge <?= $sslClass ?>"><?= fresk_h($sslLabel) ?></span></td>
            <td class="small"><?= $r['method'] === 'dns-01' ? te('ssl.m_dns') : ($r['method'] === 'http-01' ? te('ssl.m_http') : '—') ?></td>
            <td class="small"><?= fresk_h((string)($r['not_after'] ?? '—')) ?></td>
            <td class="small text-muted"><?= fresk_h((string)($r['issuer'] ?? '—')) ?></td>
            <td class="text-nowrap"><?= fresk_webmail_ssl_cell((string)$r['name']) ?></td>
            <td class="text-nowrap">
              <form method="post" class="d-inline">
                <?= fresk_csrf_field() ?>
                <input type="hidden" name="action" value="status">
                <input type="hidden" name="domain" value="<?= fresk_h($r['name']) ?>">
                <button type="submit" class="btn btn-sm btn-outline-secondary">Estado</button>
              </form>
              <?php if ($ssl !== 'active' || (!empty($r['note']) && $r['note'] !== 'dns-mismatch')): ?>
              <form method="post" class="d-inline" onsubmit="return confirm('¿Emitir certificado Let\\'s Encrypt para <?= fresk_h($r['name']) ?>?');">
                <?= fresk_csrf_field() ?>
                <input type="hidden" name="action" value="issue">
                <input type="hidden" name="domain" value="<?= fresk_h($r['name']) ?>">
                <button type="submit" class="btn btn-sm btn-fresk-success">Obtener SSL</button>
              </form>
              <?php else: ?>
              <span class="text-muted small ms-1">HTTPS OK</span>
              <?php endif; ?>
            </td>
          </tr>
        <?php endforeach; endif; ?>
        </tbody>
      </table>
    </div>
  </div>
</div>
<?php fresk_layout_end(); ?>
