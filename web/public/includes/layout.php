<?php
/**
 * Layout compartido Bootstrap 5 (fase 8).
 * Uso: fresk_layout_start($title, $navKey); … contenido …; fresk_layout_end();
 */
declare(strict_types=1);

/** @return list<array{key:string,label:string,href:string,icon:string}> */
function fresk_nav_items(): array {
    $b = fresk_base();
    return [
        ['key' => 'dashboard', 'label' => t('nav.dashboard'), 'href' => $b . '/',            'icon' => 'bi-speedometer2'],
        ['key' => 'domains',   'label' => t('nav.domains'),   'href' => $b . '/domains.php', 'icon' => 'bi-globe2'],
        ['key' => 'files',     'label' => t('nav.files'),     'href' => $b . '/files.php',   'icon' => 'bi-folder2-open'],
        ['key' => 'mail',      'label' => t('nav.mail'),      'href' => $b . '/mail.php',    'icon' => 'bi-envelope'],
        ['key' => 'dns',       'label' => t('nav.dns'),       'href' => $b . '/dns.php',     'icon' => 'bi-diagram-3'],
        ['key' => 'ssl',       'label' => t('nav.ssl'),       'href' => $b . '/ssl.php',     'icon' => 'bi-shield-lock'],
        ['key' => 'db',        'label' => t('nav.db'),        'href' => $b . '/db.php',      'icon' => 'bi-database'],
        ['key' => 'sftp',      'label' => t('nav.sftp'),      'href' => $b . '/sftp.php',    'icon' => 'bi-folder-symlink'],
        // Siempre el último: anclado abajo del menú lateral
    ];
}

/** Menú de usuario (desplegable verde de la cabecera). @return list<array{key:string,label:string,href:string,icon:string}> */
function fresk_user_menu_items(): array {
    $b = fresk_base();
    return [
        ['key' => 'profile',  'label' => t('menu.profile'),  'href' => $b . '/profile.php',  'icon' => 'bi-person-vcard'],
        ['key' => 'language', 'label' => t('menu.language'), 'href' => $b . '/language.php', 'icon' => 'bi-translate'],
        ['key' => 'upgrade',  'label' => t('mini.menu_upgrade'), 'href' => FLESK_MINI_REGISTER, 'icon' => 'bi-rocket-takeoff'],
    ];
}

function fresk_asset(string $rel): string {
    return htmlspecialchars(fresk_base() . '/assets/' . ltrim($rel, '/'), ENT_QUOTES, 'UTF-8');
}

/** URL de asset con clave de caché versión + mtime (el navegador recarga CSS/JS al cambiar). */
function fresk_asset_v(string $rel): string {
    $file = dirname(__DIR__, 2) . '/assets/' . ltrim($rel, '/');
    $m = @filemtime($file);
    return fresk_asset($rel) . '?v=' . rawurlencode(fresk_version() . ($m ? '-' . $m : ''));
}

function fresk_version(): string {
    static $v = null;
    if ($v !== null) return $v;
    foreach (['/opt/flesk/VERSION', dirname(__DIR__, 3) . '/VERSION'] as $f) {
        if (is_readable($f)) {
            $v = trim((string)file_get_contents($f));
            if ($v !== '') return $v;
        }
    }
    return $v = '?';
}

/** Logo FLESK: 3 cubos isométricos (mismo diseño que la página de bienvenida). */
function fresk_logo_svg(string $id = 'lg', string $class = 'fresk-logo'): string {
    $i = preg_replace('/[^a-z0-9]/i', '', $id);
    return '<svg class="' . fresk_h($class) . '" viewBox="0 0 120 120" aria-hidden="true" focusable="false">'
        . '<defs>'
        . '<linearGradient id="' . $i . 't" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#e9fff8"/><stop offset="1" stop-color="#8fdcc8"/></linearGradient>'
        . '<linearGradient id="' . $i . 'l" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3fb89c"/><stop offset="1" stop-color="#1f7f6d"/></linearGradient>'
        . '<linearGradient id="' . $i . 'r" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1f7f6d"/><stop offset="1" stop-color="#0f3d35"/></linearGradient>'
        . '</defs>'
        . '<g class="cube c1"><polygon class="cube-top" points="60,8 88,24 60,40 32,24" fill="url(#' . $i . 't)"/>'
        . '<polygon points="32,24 60,40 60,70 32,54" fill="url(#' . $i . 'l)"/><polygon points="88,24 60,40 60,70 88,54" fill="url(#' . $i . 'r)"/></g>'
        . '<g class="cube c2"><polygon points="32,58 58,73 32,88 6,73" fill="url(#' . $i . 't)"/>'
        . '<polygon points="6,73 32,88 32,114 6,99" fill="url(#' . $i . 'l)"/><polygon points="58,73 32,88 32,114 58,99" fill="url(#' . $i . 'r)"/></g>'
        . '<g class="cube c3"><polygon points="88,58 114,73 88,88 62,73" fill="url(#' . $i . 't)"/>'
        . '<polygon points="62,73 88,88 88,114 62,99" fill="url(#' . $i . 'l)"/><polygon points="114,73 88,88 88,114 114,99" fill="url(#' . $i . 'r)"/></g>'
        . '</svg>';
}

/**
 * Capa decorativa de triángulos menta (baja opacidad, deriva lenta).
 * $variant: 'app' (esquinas del fondo), 'login' (más expresiva), 'sidebar'.
 */
function fresk_triangles_svg(string $variant = 'app'): string {
    if ($variant === 'sidebar') {
        return '<svg class="fresk-deco fresk-deco-sidebar" viewBox="0 0 240 320" preserveAspectRatio="xMidYMax slice" aria-hidden="true" focusable="false">'
            . '<g class="d1"><polygon points="0,320 0,170 130,320" fill="#5fc4ad" opacity=".18"/><polygon points="0,170 90,240 0,260" fill="#8fdcc8" opacity=".14"/></g>'
            . '<g class="d2"><polygon points="240,320 240,120 110,320" fill="#1f7f6d" opacity=".35"/><polygon points="240,120 160,230 240,250" fill="#bff0e2" opacity=".10"/></g>'
            . '<g class="d3"><polygon points="90,240 170,300 60,320" fill="#8fdcc8" opacity=".12"/></g>'
            . '</svg>';
    }
    if ($variant === 'login') {
        return '<svg class="fresk-deco fresk-deco-login" viewBox="0 0 1600 900" preserveAspectRatio="xMidYMid slice" aria-hidden="true" focusable="false">'
            . '<g class="d1"><polygon points="0,0 420,0 0,460" fill="#5fc4ad" opacity=".35"/><polygon points="420,0 860,0 640,300" fill="#ffffff" opacity=".55"/>'
            . '<polygon points="0,460 300,280 430,640" fill="#8fdcc8" opacity=".35"/></g>'
            . '<g class="d2"><polygon points="860,0 1280,0 1040,400" fill="#bff0e2" opacity=".55"/><polygon points="1280,0 1600,0 1600,380" fill="#5fc4ad" opacity=".30"/>'
            . '<polygon points="1040,400 1600,380 1320,760" fill="#e6fbf5" opacity=".7"/></g>'
            . '<g class="d3"><polygon points="0,720 320,600 0,900" fill="#1f7f6d" opacity=".22"/><polygon points="320,600 720,660 460,900" fill="#8fdcc8" opacity=".30"/>'
            . '<polygon points="1320,760 1600,640 1600,900" fill="#5fc4ad" opacity=".30"/><polygon points="720,660 1320,760 920,900" fill="#bff0e2" opacity=".45"/></g>'
            . '</svg>';
    }
    return '<svg class="fresk-deco fresk-deco-app" viewBox="0 0 1600 900" preserveAspectRatio="xMidYMid slice" aria-hidden="true" focusable="false">'
        . '<g class="d1"><polygon points="1600,0 1600,300 1320,0" fill="#8fdcc8" opacity=".22"/><polygon points="1320,0 1480,170 1180,110" fill="#bff0e2" opacity=".35"/></g>'
        . '<g class="d2"><polygon points="1600,300 1450,190 1600,470" fill="#5fc4ad" opacity=".12"/></g>'
        . '<g class="d3"><polygon points="0,900 0,640 250,900" fill="#8fdcc8" opacity=".20"/><polygon points="250,900 150,760 420,860" fill="#bff0e2" opacity=".35"/>'
        . '<polygon points="0,640 110,720 0,560" fill="#5fc4ad" opacity=".10"/></g>'
        . '</svg>';
}

/** Botón ojo mostrar/ocultar contraseña para el input con id $id. */
function fresk_pw_toggle(string $id): string {
    return '<button class="btn btn-outline-secondary fresk-pw-toggle" type="button" data-pw-toggle="' . fresk_h($id) . '" aria-controls="' . fresk_h($id) . '"'
        . ' aria-pressed="false" aria-label="' . te('pw.show') . '" title="' . te('pw.show') . '"'
        . ' data-label-show="' . te('pw.show') . '" data-label-hide="' . te('pw.hide') . '"><i class="bi bi-eye"></i></button>';
}

/** Etiquetas de favicon (logo 3 cubos). */
function fresk_favicon_tags(): string {
    $v = '?v=' . rawurlencode(fresk_version());
    return '<link rel="icon" type="image/svg+xml" href="' . fresk_asset('img/favicon.svg') . $v . '">' . "\n"
        . '  <link rel="icon" type="image/png" sizes="32x32" href="' . fresk_asset('img/favicon-32.png') . $v . '">' . "\n"
        . '  <link rel="icon" href="' . fresk_asset('img/favicon.ico') . $v . '" sizes="any">' . "\n"
        . '  <link rel="apple-touch-icon" href="' . fresk_asset('img/apple-touch-icon.png') . $v . '">';
}

/** Pie con créditos (todas las páginas y login). */
function fresk_footer_html(): string {
    return '<footer class="fresk-footer"><span>' . fresk_h('Flesk Mini ' . fresk_version() . ' · digitacode.es · ') . '<a href="' . fresk_h(FLESK_MINI_SITE) . '" target="_blank" rel="noopener">serverflesk.es</a> · ' . te('mini.footer') . '</span></footer>';
}

/** Traduce títulos de páginas existentes (pasados en español) según navKey. */
function fresk_localize_title(string $navKey, string $title): string {
    $key = 'page.' . $navKey;
    if (!fresk_t_has($key)) return $title;
    $es = (string)(fresk_lang_pack('es')[$key] ?? '');
    $esNav = (string)(fresk_lang_pack('es')['nav.' . $navKey] ?? '');
    if ($title === $es || $title === $esNav) return t($key);
    return $title;
}

/**
 * @param string $title  Título de página
 * @param string $navKey Clave activa del menú
 * @param list<string> $breadcrumbs etiquetas extra tras Dashboard
 */
function fresk_layout_start(string $title, string $navKey, array $breadcrumbs = []): void {
    $base = fresk_base();
    $user = (string)($_SESSION['fresk_admin_user'] ?? 'admin');
    $items = fresk_nav_items();
    $menu = fresk_user_menu_items();
    $title = fresk_localize_title($navKey, $title);
    $breadcrumbs = array_map(static fn($b) => fresk_localize_title($navKey, (string)$b), $breadcrumbs);
    $pageTitle = $title . ' · Flesk';
    if ($breadcrumbs === []) {
        $breadcrumbs = [$title];
    }
    $menuActive = in_array($navKey, array_column($menu, 'key'), true);
    ?>
<!DOCTYPE html>
<html lang="<?= fresk_h(fresk_lang()) ?>">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="theme-color" content="#0f3d35">
  <title><?= fresk_h($pageTitle) ?></title>
  <?= fresk_favicon_tags() ?>
  <link rel="stylesheet" href="<?= fresk_asset('css/bootstrap.min.css') ?>">
  <link rel="stylesheet" href="<?= fresk_asset('css/bootstrap-icons.css') ?>">
  <link rel="stylesheet" href="<?= fresk_asset_v('css/fresk-panel.css') ?>">
</head>
<body class="fresk-app">
  <div class="fresk-bg" aria-hidden="true"><?= fresk_triangles_svg('app') ?><div class="fresk-sweep"></div></div>
  <!-- Sidebar desktop -->
  <aside class="fresk-sidebar d-none d-lg-flex flex-column">
    <?= fresk_triangles_svg('sidebar') ?>
    <a class="brand" href="<?= fresk_h($base . '/') ?>"><?= fresk_logo_svg('sb') ?><span class="brand-word">FLESK</span><span class="badge bg-success ms-1 align-middle" style="font-size:.6rem">MINI</span></a>
    <nav class="nav flex-column py-2 flex-grow-1">
      <?php foreach ($items as $it): ?>
        <a class="nav-link<?= $navKey === $it['key'] ? ' active' : '' ?><?= !empty($it['bottom']) ? ' mt-auto nav-link-bottom' : '' ?>" href="<?= fresk_h($it['href']) ?>">
          <i class="bi <?= fresk_h($it['icon']) ?>"></i> <?= fresk_h($it['label']) ?>
        </a>
      <?php endforeach; ?>
    </nav>
    <div class="sidebar-user p-3 small">
      <i class="bi bi-person-circle me-1"></i><?= fresk_h($user) ?>
    </div>
  </aside>

  <!-- Offcanvas mobile -->
  <div class="offcanvas offcanvas-start fresk-offcanvas" tabindex="-1" id="freskNav" aria-labelledby="freskNavLabel">
    <div class="offcanvas-header">
      <h5 class="offcanvas-title text-white d-flex align-items-center gap-2" id="freskNavLabel"><?= fresk_logo_svg('oc') ?> FLESK</h5>
      <button type="button" class="btn-close btn-close-white" data-bs-dismiss="offcanvas" aria-label="<?= te('nav.close') ?>"></button>
    </div>
    <div class="offcanvas-body p-0">
      <nav class="nav flex-column py-2">
        <?php foreach ($items as $it): ?>
          <a class="nav-link<?= $navKey === $it['key'] ? ' active' : '' ?>" href="<?= fresk_h($it['href']) ?>">
            <i class="bi <?= fresk_h($it['icon']) ?>"></i> <?= fresk_h($it['label']) ?>
          </a>
        <?php endforeach; ?>
        <hr class="border-light opacity-25 my-2">
        <?php foreach ($menu as $it): ?>
          <a class="nav-link<?= $navKey === $it['key'] ? ' active' : '' ?>" href="<?= fresk_h($it['href']) ?>">
            <i class="bi <?= fresk_h($it['icon']) ?>"></i> <?= fresk_h($it['label']) ?>
          </a>
        <?php endforeach; ?>
        <a class="nav-link" href="<?= fresk_h($base . '/logout.php') ?>"><i class="bi bi-box-arrow-right"></i> <?= te('nav.logout') ?></a>
      </nav>
    </div>
  </div>

  <div class="fresk-main">
    <header class="fresk-header d-flex align-items-center justify-content-between gap-2">
      <div class="d-flex align-items-center gap-2 min-w-0">
        <button class="btn btn-sm btn-outline-secondary d-lg-none" type="button" data-bs-toggle="offcanvas" data-bs-target="#freskNav" aria-controls="freskNav" aria-label="<?= te('nav.menu') ?>">
          <i class="bi bi-list"></i>
        </button>
        <nav aria-label="breadcrumb" class="min-w-0">
          <ol class="breadcrumb mb-0 text-truncate">
            <li class="breadcrumb-item"><a href="<?= fresk_h($base . '/') ?>"><?= te('nav.home') ?></a></li>
            <?php
            $last = count($breadcrumbs) - 1;
            foreach ($breadcrumbs as $i => $bc):
              if ($i === $last): ?>
                <li class="breadcrumb-item active" aria-current="page"><?= fresk_h($bc) ?></li>
              <?php else: ?>
                <li class="breadcrumb-item"><?= fresk_h($bc) ?></li>
              <?php endif;
            endforeach; ?>
          </ol>
        </nav>
      </div>
      <div class="d-flex align-items-center gap-3 text-secondary small flex-shrink-0">
        <span class="d-none d-md-inline" title="<?= te('header.search') ?>"><i class="bi bi-search"></i></span>
        <span class="d-none d-md-inline" title="<?= te('header.alerts') ?>"><i class="bi bi-bell"></i></span>
        <div class="dropdown fresk-user-dropdown">
          <button class="btn btn-success btn-sm dropdown-toggle fresk-user-btn<?= $menuActive ? ' active' : '' ?>" type="button" id="freskUserMenu"
                  data-bs-toggle="dropdown" data-bs-display="static" aria-expanded="false" aria-label="<?= te('header.user_menu') ?>">
            <i class="bi bi-person-circle"></i><span class="fresk-user-name"><?= fresk_h($user) ?></span>
          </button>
          <ul class="dropdown-menu dropdown-menu-end shadow fresk-user-menu" aria-labelledby="freskUserMenu">
            <li><h6 class="dropdown-header"><?= te('header.signed_as') ?> <strong><?= fresk_h($user) ?></strong></h6></li>
            <?php foreach ($menu as $it): ?>
              <li><a class="dropdown-item<?= $navKey === $it['key'] ? ' active' : '' ?>" href="<?= fresk_h($it['href']) ?>"><i class="bi <?= fresk_h($it['icon']) ?>"></i><?= fresk_h($it['label']) ?></a></li>
            <?php endforeach; ?>
            <li><hr class="dropdown-divider"></li>
            <li><a class="dropdown-item text-danger" href="<?= fresk_h($base . '/logout.php') ?>"><i class="bi bi-box-arrow-right"></i><?= te('menu.logout') ?></a></li>
          </ul>
        </div>
      </div>
    </header>
    <main class="fresk-content">
<?php
    $miniRes = ['domains' => 'domain', 'mail' => 'mail', 'ssl' => 'ssl', 'db' => 'db', 'sftp' => 'sftp'][$navKey] ?? null;
    if ($miniRes !== null) echo fresk_mini_limit_notice($miniRes);
}

function fresk_layout_end(): void {
    ?>
    </main>
    <?= fresk_footer_html() ?>
  </div>
  <script src="<?= fresk_asset('js/bootstrap.bundle.min.js') ?>"></script>
  <script src="<?= fresk_asset_v('js/fresk-ui.js') ?>"></script>
  <script>
  // Filtro instantáneo en cliente: <input data-live-filter="#tabla"> filtra filas con data-filter-text
  (function () {
    document.querySelectorAll('[data-live-filter]').forEach(function (inp) {
      var sel = inp.getAttribute('data-live-filter');
      function run() {
        var q = inp.value.trim().toLowerCase(), n = 0;
        document.querySelectorAll(sel).forEach(function (tbl) {
          tbl.querySelectorAll('tbody tr[data-filter-text]').forEach(function (tr) {
            var ok = q === '' || tr.getAttribute('data-filter-text').indexOf(q) !== -1;
            tr.hidden = !ok; if (ok) n++;
          });
        });
        document.querySelectorAll('[data-count-for]').forEach(function (c) {
          var k = 0;
          document.querySelectorAll(c.getAttribute('data-count-for')).forEach(function (t) {
            k += t.querySelectorAll('tbody tr[data-filter-text]:not([hidden])').length;
          });
          c.textContent = String(k);
        });
      }
      inp.addEventListener('input', run);
    });
  })();
  // Contador animado de KPIs (solo si el usuario no pide movimiento reducido; el valor final ya está en el HTML)
  (function () {
    if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    document.querySelectorAll('[data-count]').forEach(function (el) {
      var end = parseInt(el.getAttribute('data-count'), 10);
      if (!(end > 0)) return;
      var t0 = null, dur = 900;
      function step(ts) {
        if (t0 === null) t0 = ts;
        var p = Math.min(1, (ts - t0) / dur);
        el.textContent = String(Math.round(end * (1 - Math.pow(1 - p, 3))));
        if (p < 1) requestAnimationFrame(step);
      }
      requestAnimationFrame(step);
    });
  })();
  </script>
</body>
</html>
<?php
}

function fresk_render_flashes(string $flash = '', string $flashErr = '', ?string $pwdOnce = null, ?string $credsBlock = null): void {
    if ($flash !== ''): ?>
      <div class="alert alert-success"><?= fresk_h($flash) ?></div>
    <?php endif;
    if ($flashErr !== ''): ?>
      <div class="alert alert-danger" style="white-space:pre-wrap;word-break:break-word"><?= fresk_h($flashErr) ?></div>
    <?php endif;
    if ($credsBlock !== null && $credsBlock !== ''): ?>
      <div class="pwd-once">
        <strong><?= te('flash.creds_once') ?></strong>
        <pre class="mb-1 mt-2" style="white-space:pre-wrap"><?= fresk_h(trim($credsBlock)) ?></pre>
        <p class="mb-0 small text-muted"><?= te('flash.creds_note') ?></p>
      </div>
    <?php elseif ($pwdOnce !== null && $pwdOnce !== ''): ?>
      <div class="pwd-once">
        <strong><?= te('flash.pwd_once') ?></strong><br>
        <code>PASSWORD=<?= fresk_h($pwdOnce) ?></code>
        <p class="mb-0 mt-1 small text-muted"><?= te('flash.pwd_note') ?></p>
      </div>
    <?php endif;
}

function fresk_csrf_field(): string {
    return '<input type="hidden" name="csrf" value="' . fresk_h(fresk_csrf_token()) . '">';
}

function fresk_status_badge(?string $status, string $fallback = '—'): string {
    $s = $status ?? '';
    if ($s === '') return '<span class="badge badge-status-none">' . fresk_h($fallback) . '</span>';
    $class = match ($s) {
        'active' => 'badge-status-active',
        'pending' => 'badge-status-pending',
        'error', 'expired' => 'badge-status-error',
        default => 'badge-status-none',
    };
    return '<span class="badge ' . $class . '">' . fresk_h($s) . '</span>';
}
