<?php
declare(strict_types=1);
require __DIR__ . '/auth.php';
require __DIR__ . '/includes/layout.php';
require __DIR__ . '/includes/captcha.php';

// Cambio de idioma antes de iniciar sesión (?lang=en|es)
if (isset($_GET['lang']) && is_string($_GET['lang'])) {
    fresk_set_session_lang(strtolower($_GET['lang']));
}

$error = '';
$u = '';
$locked = fresk_login_is_locked();
if (!empty($_SESSION['fresk_admin_id'])) {
    header('Location: ' . fresk_base() . '/');
    exit;
}
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $u = trim((string)($_POST['username'] ?? ''));
    $p = (string)($_POST['password'] ?? '');
    if ($locked || fresk_login_is_locked($u)) {
        $error = t('login.locked');
        $locked = true;
    } elseif ($u === '' || $p === '') {
        $error = t('login.required');
        unset($_SESSION['fresk_captcha']);
    } elseif (!fresk_captcha_verify()) {
        // Captcha inválido: no se comprueban credenciales (el reto ya se consumió)
        $error = t('captcha.fail');
        usleep(200000);
    } elseif (fresk_login($u, $p)) {
        fresk_audit('panel.login', mb_substr($u, 0, 64), 'ok', 'ip=' . (string)($_SERVER['REMOTE_ADDR'] ?? ''));
        header('Location: ' . fresk_base() . '/');
        exit;
    } else {
        fresk_audit('panel.login', mb_substr($u, 0, 64), 'error', 'ip=' . (string)($_SERVER['REMOTE_ADDR'] ?? ''));
        if (fresk_login_is_locked($u)) {
            $error = t('login.locked5');
            $locked = true;
        } else {
            $error = t('login.bad');
        }
        usleep(300000);
    }
}
$base = fresk_base();
$cur = fresk_lang();
$cap = fresk_captcha_new();   // reto nuevo en cada carga (y tras cada intento)
?><!DOCTYPE html>
<html lang="<?= fresk_h($cur) ?>">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="theme-color" content="#0f3d35">
  <title>Flesk · <?= te('login.title') ?></title>
  <?= fresk_favicon_tags() ?>
  <link rel="stylesheet" href="<?= fresk_asset('css/bootstrap.min.css') ?>">
  <link rel="stylesheet" href="<?= fresk_asset('css/bootstrap-icons.css') ?>">
  <link rel="stylesheet" href="<?= fresk_asset_v('css/fresk-panel.css') ?>">
</head>
<body class="fresk-login-body">
  <div class="fresk-bg" aria-hidden="true"><?= fresk_triangles_svg('login') ?><div class="fresk-sweep"></div></div>
  <div class="fresk-login-wrap">
    <div class="card fresk-login-card">
      <div class="card-body p-4">
        <div class="fresk-login-brand"><?= fresk_logo_svg('lo') ?><span class="word">FLESK</span></div>
        <p class="text-muted small mb-3"><?= te('login.subtitle') ?></p>
        <h1 class="h5 mb-3"><?= te('login.title') ?></h1>
        <?php if ($error): ?><div class="alert alert-danger py-2"><?= fresk_h($error) ?></div><?php endif; ?>
        <form method="post" autocomplete="off">
          <div class="mb-3">
            <label class="form-label" for="username"><?= te('login.user') ?></label>
            <input class="form-control" id="username" name="username" required autocapitalize="none" autocomplete="username" maxlength="64"
                   value="<?= fresk_h($u ?? '') ?>" <?= ($u ?? '') === '' ? 'autofocus' : '' ?> <?= $locked ? 'disabled' : '' ?>>
          </div>
          <div class="mb-3">
            <label class="form-label" for="password"><?= te('login.pass') ?></label>
            <div class="input-group fresk-pw">
              <input class="form-control" id="password" name="password" type="password" required autocomplete="current-password" <?= ($u ?? '') !== '' ? 'autofocus' : '' ?> <?= $locked ? 'disabled' : '' ?>>
              <button class="btn btn-outline-secondary fresk-pw-toggle" type="button" data-pw-toggle="password" aria-controls="password" aria-pressed="false"
                      aria-label="<?= te('pw.show') ?>" title="<?= te('pw.show') ?>" data-label-show="<?= te('pw.show') ?>" data-label-hide="<?= te('pw.hide') ?>"><i class="bi bi-eye"></i></button>
            </div>
          </div>
          <div class="fresk-captcha mb-3" data-captcha data-piece="<?= FRESK_CAPTCHA_PIECE ?>" data-w="<?= FRESK_CAPTCHA_W ?>" data-y="<?= (int)$cap['y'] ?>" data-ok="<?= te('captcha.ok') ?>">
            <div class="fresk-captcha-title small fw-semibold mb-1"><i class="bi bi-puzzle me-1"></i><?= te('captcha.title') ?></div>
            <div class="fresk-captcha-box">
              <div class="fresk-captcha-stage" style="aspect-ratio:<?= FRESK_CAPTCHA_W ?>/<?= FRESK_CAPTCHA_H ?>">
                <img class="fresk-captcha-img" src="<?= fresk_h($base . '/captcha.php?t=' . $cap['token']) ?>" width="<?= FRESK_CAPTCHA_W ?>" height="<?= FRESK_CAPTCHA_H ?>" alt="<?= te('captcha.img') ?>" draggable="false">
                <div class="fresk-captcha-piece" style="top:<?= round($cap['y'] / FRESK_CAPTCHA_H * 100, 4) ?>%;width:<?= round(FRESK_CAPTCHA_PIECE / FRESK_CAPTCHA_W * 100, 4) ?>%;height:<?= round(FRESK_CAPTCHA_PIECE / FRESK_CAPTCHA_H * 100, 4) ?>%"><?= fresk_logo_svg('cp') ?></div>
              </div>
              <div class="fresk-captcha-track">
                <div class="fresk-captcha-fill"></div>
                <div class="fresk-captcha-handle" role="slider" tabindex="0" aria-label="<?= te('captcha.handle') ?>" aria-valuemin="0" aria-valuemax="<?= FRESK_CAPTCHA_W - FRESK_CAPTCHA_PIECE ?>" aria-valuenow="0"
                     style="width:<?= round(FRESK_CAPTCHA_PIECE / FRESK_CAPTCHA_W * 100, 4) ?>%"><i class="bi bi-arrow-right"></i></div>
              </div>
            </div>
            <div class="form-text small fresk-captcha-help"><?= te('captcha.help') ?></div>
            <input type="hidden" name="captcha_token" value="<?= fresk_h($cap['token']) ?>">
            <input type="hidden" name="captcha_x" value="">
            <input type="hidden" name="captcha_trace" value="">
          </div>
          <button class="btn btn-fresk-primary w-100" type="submit" <?= $locked ? 'disabled' : '' ?>><i class="bi bi-box-arrow-in-right me-1"></i><?= te('login.submit') ?></button>
        </form>
        <div class="fresk-lang-switch small text-center mt-3">
          <i class="bi bi-translate me-1"></i><?= te('login.lang') ?>:
          <?php $first = true; foreach (fresk_available_langs() as $code => $name): ?>
            <?= $first ? '' : ' | ' ?><a href="?lang=<?= fresk_h($code) ?>" class="<?= $code === $cur ? 'active' : '' ?>" hreflang="<?= fresk_h($code) ?>"><?= fresk_h($name) ?></a>
          <?php $first = false; endforeach; ?>
        </div>
      </div>
    </div>
    <?= fresk_footer_html() ?>
  </div>
  <script src="<?= fresk_asset_v('js/fresk-ui.js') ?>"></script>
</body>
</html>
