<?php
declare(strict_types=1);
require __DIR__ . '/auth.php';
fresk_require_login();
require __DIR__ . '/includes/layout.php';

$flash = (string)($_SESSION['fresk_flash'] ?? '');
unset($_SESSION['fresk_flash']);
$flashErr = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    fresk_csrf_check();
    $code = strtolower(trim((string)($_POST['language'] ?? '')));
    if (!fresk_lang_valid($code)) {
        $flashErr = t('lang.invalid');
    } else {
        try {
            fresk_pdo()->prepare('UPDATE admins SET language = ? WHERE id = ?')
                ->execute([$code, (int)$_SESSION['fresk_admin_id']]);
            fresk_set_session_lang($code);
            fresk_audit('panel.language.set', (string)($_SESSION['fresk_admin_user'] ?? ''), 'ok', 'lang=' . $code);
            $_SESSION['fresk_flash'] = t('lang.saved');
            header('Location: ' . fresk_base() . '/language.php');
            exit;
        } catch (Throwable $e) {
            error_log('flesk language: ' . $e->getMessage());
            $flashErr = t('common.error_db');
        }
    }
}

$cur = fresk_lang();
$def = fresk_default_lang();
$flags = ['es' => 'ES', 'en' => 'EN'];
fresk_layout_start(t('page.language'), 'language');
?>
<div class="d-flex justify-content-between align-items-center mb-3 flex-wrap gap-2">
  <h1 class="h4 mb-0"><i class="bi bi-translate me-2"></i><?= te('page.language') ?></h1>
</div>
<?php fresk_render_flashes($flash, $flashErr); ?>
<div class="row g-3">
  <div class="col-lg-7">
    <div class="card fresk-card h-100">
      <div class="card-body">
        <p class="text-muted"><?= te('lang.intro') ?></p>
        <form method="post">
          <?= fresk_csrf_field() ?>
          <fieldset>
            <legend class="form-label fs-6 fw-semibold"><?= te('lang.choose') ?></legend>
            <?php foreach (fresk_available_langs() as $code => $name): ?>
              <div class="form-check mb-2">
                <input class="form-check-input" type="radio" name="language" id="lang_<?= fresk_h($code) ?>" value="<?= fresk_h($code) ?>" <?= $code === $cur ? 'checked' : '' ?>>
                <label class="form-check-label" for="lang_<?= fresk_h($code) ?>">
                  <span class="badge text-bg-light border me-1"><?= fresk_h($flags[$code] ?? strtoupper($code)) ?></span><?= fresk_h($name) ?>
                  <?php if ($code === $def): ?><span class="text-muted small">(<?= te('lang.default') ?>)</span><?php endif; ?>
                </label>
              </div>
            <?php endforeach; ?>
          </fieldset>
          <button class="btn btn-fresk-primary mt-2" type="submit"><i class="bi bi-check2 me-1"></i><?= te('common.save') ?></button>
        </form>
      </div>
    </div>
  </div>
  <div class="col-lg-5">
    <div class="card fresk-card h-100">
      <div class="card-body">
        <h2 class="card-title"><?= te('lang.installed') ?></h2>
        <ul class="list-unstyled mb-0">
          <?php foreach (fresk_available_langs() as $code => $name): ?>
            <li class="py-1"><i class="bi bi-check-circle-fill text-success me-2"></i><?= fresk_h($name) ?> <code><?= fresk_h($code) ?></code></li>
          <?php endforeach; ?>
        </ul>
        <p class="small text-muted mt-3 mb-0"><?= te('lang.current') ?>: <strong><?= fresk_h(fresk_available_langs()[$cur] ?? $cur) ?></strong></p>
      </div>
    </div>
  </div>
</div>
<?php fresk_layout_end(); ?>
