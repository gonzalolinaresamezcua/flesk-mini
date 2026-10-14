<?php
declare(strict_types=1);
require __DIR__ . '/auth.php';
fresk_require_login();
require __DIR__ . '/includes/layout.php';

$kpiDomains = $kpiMail = $kpiSsl = $kpiDb = 0;
try {
    $pdo = fresk_pdo();
    $kpiDomains = (int)$pdo->query('SELECT COUNT(*) FROM domains')->fetchColumn();
    $kpiMail    = (int)$pdo->query('SELECT COUNT(*) FROM mailboxes')->fetchColumn();
    $kpiSsl     = (int)$pdo->query("SELECT COUNT(*) FROM ssl_certs WHERE status='active'")->fetchColumn();
    $kpiDb      = (int)$pdo->query('SELECT COUNT(*) FROM `databases`')->fetchColumn();
} catch (Throwable $e) {
    $kpiDomains = $kpiMail = $kpiSsl = $kpiDb = -1;
}
$base = fresk_base();
fresk_layout_start(t('page.dashboard'), 'dashboard', [t('page.dashboard')]);
?>
<div class="d-flex justify-content-between align-items-center mb-3 flex-wrap gap-2">
  <h1 class="h4 mb-0"><?= te('page.dashboard') ?></h1>
  <span class="text-muted small"><?= te('dash.kpi_source') ?></span>
</div>

<?= fresk_mini_promo_html() ?>

<div class="row g-3 mb-4">
  <div class="col-6 col-lg-3">
    <div class="card kpi-card kpi-orange h-100">
      <div class="card-body d-flex align-items-center gap-3">
        <div class="kpi-icon"><i class="bi bi-globe2"></i></div>
        <div>
          <div class="kpi-value" data-count="<?= max(0, $kpiDomains) ?>"><?= $kpiDomains >= 0 ? $kpiDomains : '?' ?></div>
          <div class="kpi-label"><?= te('dash.domains') ?></div>
        </div>
      </div>
    </div>
  </div>
  <div class="col-6 col-lg-3">
    <div class="card kpi-card kpi-blue h-100">
      <div class="card-body d-flex align-items-center gap-3">
        <div class="kpi-icon"><i class="bi bi-envelope"></i></div>
        <div>
          <div class="kpi-value" data-count="<?= max(0, $kpiMail) ?>"><?= $kpiMail >= 0 ? $kpiMail : '?' ?></div>
          <div class="kpi-label"><?= te('dash.mailboxes') ?></div>
        </div>
      </div>
    </div>
  </div>
  <div class="col-6 col-lg-3">
    <div class="card kpi-card kpi-green h-100">
      <div class="card-body d-flex align-items-center gap-3">
        <div class="kpi-icon"><i class="bi bi-shield-check"></i></div>
        <div>
          <div class="kpi-value" data-count="<?= max(0, $kpiSsl) ?>"><?= $kpiSsl >= 0 ? $kpiSsl : '?' ?></div>
          <div class="kpi-label"><?= te('dash.ssl') ?></div>
        </div>
      </div>
    </div>
  </div>
  <div class="col-6 col-lg-3">
    <div class="card kpi-card kpi-navy h-100">
      <div class="card-body d-flex align-items-center gap-3">
        <div class="kpi-icon"><i class="bi bi-database"></i></div>
        <div>
          <div class="kpi-value" data-count="<?= max(0, $kpiDb) ?>"><?= $kpiDb >= 0 ? $kpiDb : '?' ?></div>
          <div class="kpi-label"><?= te('dash.dbs') ?></div>
        </div>
      </div>
    </div>
  </div>
</div>

<div class="card fresk-card">
  <div class="card-body">
    <h2 class="card-title"><?= te('dash.quick') ?></h2>
    <div class="d-flex flex-wrap gap-2">
      <a class="btn btn-fresk-primary btn-sm" href="<?= fresk_h($base . '/domains.php') ?>"><i class="bi bi-plus-lg"></i> <?= te('dash.q_domains') ?></a>
      <a class="btn btn-fresk btn-sm" href="<?= fresk_h($base . '/mail.php') ?>"><i class="bi bi-envelope"></i> <?= te('dash.q_mail') ?></a>
      <a class="btn btn-fresk btn-sm" href="<?= fresk_h($base . '/dns.php') ?>"><i class="bi bi-diagram-3"></i> <?= te('dash.q_dns') ?></a>
      <a class="btn btn-fresk-success btn-sm" href="<?= fresk_h($base . '/ssl.php') ?>"><i class="bi bi-shield-lock"></i> <?= te('dash.q_ssl') ?></a>
      <a class="btn btn-fresk btn-sm" href="<?= fresk_h($base . '/db.php') ?>"><i class="bi bi-database"></i> <?= te('dash.q_db') ?></a>
      <a class="btn btn-fresk btn-sm" href="<?= fresk_h($base . '/sftp.php') ?>"><i class="bi bi-folder-symlink"></i> <?= te('dash.q_sftp') ?></a>
    </div>
  </div>
</div>
<?php fresk_layout_end(); ?>
