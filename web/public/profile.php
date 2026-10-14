<?php
declare(strict_types=1);
require __DIR__ . '/auth.php';
fresk_require_login();
require __DIR__ . '/includes/layout.php';

/** Campos del perfil: nombre => [longitud máx, tipo] */
$fields = [
    'company'      => [190, 'text'],
    'tax_id'       => [32,  'text'],
    'contact_name' => [190, 'text'],
    'email'        => [190, 'email'],
    'phone'        => [40,  'tel'],
    'address'      => [255, 'text'],
    'city'         => [120, 'text'],
    'postal_code'  => [16,  'text'],
    'country'      => [120, 'text'],
    'website'      => [255, 'url'],
    'notes'        => [2000, 'textarea'],
];

$flash = (string)($_SESSION['fresk_flash'] ?? '');
unset($_SESSION['fresk_flash']);
$flashErr = '';
$data = array_fill_keys(array_keys($fields), '');
$updated = null;

try {
    $row = fresk_pdo()->query('SELECT * FROM panel_profile WHERE id = 1')->fetch();
    if ($row) {
        foreach ($fields as $k => $_) $data[$k] = (string)($row[$k] ?? '');
        $updated = $row['updated_at'] ?? null;
    }
} catch (Throwable $e) {
    $flashErr = t('common.error_db');
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    fresk_csrf_check();
    $in = [];
    foreach ($fields as $k => [$max, $type]) {
        $v = trim((string)($_POST[$k] ?? ''));
        $v = str_replace("\0", '', $v);
        if ($type !== 'textarea') $v = preg_replace('/[\r\n\t]+/', ' ', $v) ?? '';
        $in[$k] = $v;
        if (mb_strlen($v, 'UTF-8') > $max) $flashErr = t('profile.err_len');
    }
    if ($flashErr === '' && $in['email'] !== '' && !filter_var($in['email'], FILTER_VALIDATE_EMAIL)) {
        $flashErr = t('profile.err_email');
    }
    if ($flashErr === '' && $in['website'] !== ''
        && (!preg_match('#^https?://#i', $in['website']) || !filter_var($in['website'], FILTER_VALIDATE_URL))) {
        $flashErr = t('profile.err_web');
    }
    if ($flashErr === '' && $in['phone'] !== '' && !preg_match('/^[0-9+().\s-]{3,40}$/', $in['phone'])) {
        $flashErr = t('profile.err_phone');
    }
    if ($flashErr === '') {
        try {
            $cols = array_keys($fields);
            $sql = 'INSERT INTO panel_profile (id, ' . implode(', ', $cols) . ', updated_by) VALUES (1, '
                . implode(', ', array_fill(0, count($cols), '?')) . ', ?) ON DUPLICATE KEY UPDATE '
                . implode(', ', array_map(static fn($c) => "$c = VALUES($c)", $cols)) . ', updated_by = VALUES(updated_by)';
            $vals = array_values($in);
            $vals[] = (string)($_SESSION['fresk_admin_user'] ?? '');
            fresk_pdo()->prepare($sql)->execute($vals);
            fresk_audit('panel.profile.update', 'panel_profile', 'ok');
            $_SESSION['fresk_flash'] = t('profile.saved');
            header('Location: ' . fresk_base() . '/profile.php');
            exit;
        } catch (Throwable $e) {
            error_log('flesk profile: ' . $e->getMessage());
            $flashErr = t('common.error_db');
        }
    }
    $data = $in;
}

fresk_layout_start(t('page.profile'), 'profile');
?>
<div class="d-flex justify-content-between align-items-center mb-3 flex-wrap gap-2">
  <h1 class="h4 mb-0"><i class="bi bi-person-vcard me-2"></i><?= te('page.profile') ?></h1>
  <?php if ($updated): ?><span class="text-muted small"><?= te('profile.updated') ?>: <?= fresk_h((string)$updated) ?></span><?php endif; ?>
</div>
<?php fresk_render_flashes($flash, $flashErr); ?>
<div class="card fresk-card">
  <div class="card-body">
    <p class="text-muted"><?= te('profile.intro') ?></p>
    <form method="post" novalidate>
      <?= fresk_csrf_field() ?>
      <div class="row g-3">
        <?php foreach ($fields as $k => [$max, $type]):
          $col = match ($k) {
              'company', 'contact_name', 'address' => 'col-md-6',
              'notes' => 'col-12',
              'postal_code' => 'col-md-2',
              default => 'col-md-4',
          }; ?>
          <div class="<?= $col ?>">
            <label class="form-label" for="f_<?= $k ?>"><?= te('profile.' . $k) ?></label>
            <?php if ($type === 'textarea'): ?>
              <textarea class="form-control" id="f_<?= $k ?>" name="<?= $k ?>" rows="4" maxlength="<?= $max ?>"><?= fresk_h($data[$k]) ?></textarea>
            <?php else: ?>
              <input class="form-control" id="f_<?= $k ?>" name="<?= $k ?>" type="<?= $type ?>" maxlength="<?= $max ?>" value="<?= fresk_h($data[$k]) ?>"
                <?= $k === 'website' ? 'placeholder="https://"' : '' ?> <?= $k === 'email' ? 'autocomplete="email"' : '' ?>>
            <?php endif; ?>
          </div>
        <?php endforeach; ?>
      </div>
      <div class="mt-4">
        <button class="btn btn-fresk-primary" type="submit"><i class="bi bi-check2 me-1"></i><?= te('common.save') ?></button>
      </div>
    </form>
  </div>
</div>
<?php fresk_layout_end(); ?>
