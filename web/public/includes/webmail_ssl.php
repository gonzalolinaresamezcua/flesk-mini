<?php
declare(strict_types=1);
// Flesk — estado y emisión del certificado de webmail.<dominio> (Roundcube), compartido por Correo y SSL.

/** null = sin vhost webmail; true = HTTPS activo; false = solo HTTP. */
function fresk_webmail_https(string $dom): ?bool {
    if (fresk_valid_domain($dom) === null) return null;
    $dir = rtrim((string)(fresk_cfg()['NGINX_ENABLED'] ?? '/etc/nginx/fresk-enabled'), '/');
    $vf = $dir . '/' . $dom . '.webmail.conf';
    if (!is_file($vf) || !is_readable($vf)) return null;
    $c = (string)@file_get_contents($vf);
    return (bool)preg_match('/listen\s+[^;]*443/', $c);
}

/** Ejecuta «flesk webmail ssl <dominio>»; devuelve [flash, error]. */
function fresk_webmail_ssl_issue(string $dom): array {
    $d = fresk_valid_domain($dom);
    if ($d === null) return ['', 'Dominio inválido'];
    $r = fresk_cli(['webmail', 'ssl', $d], null, 180.0);
    $out = trim($r['stderr'] . ' ' . $r['stdout']);
    if ($r['code'] === 0) {
        return ['Webmail HTTPS activo: https://webmail.' . $d . '/', ''];
    }
    $msg = trim(preg_replace('/^.*?ERROR:\s*/s', '', $out) ?? $out);
    return ['', 'Webmail SSL (' . $r['code'] . '): ' . $msg];
}

/** Badge + botón «Webmail HTTPS» (POST action=webmail_ssl) para un dominio. */
function fresk_webmail_ssl_cell(string $dom): string {
    $st = fresk_webmail_https($dom);
    $host = 'webmail.' . $dom;
    if ($st === true) {
        return '<a class="badge badge-status-active text-decoration-none" href="https://' . fresk_h($host) . '/" target="_blank" rel="noopener" title="' . fresk_h($host) . '"><i class="bi bi-lock-fill"></i> HTTPS</a>';
    }
    $badge = $st === null
        ? '<span class="badge badge-status-none" title="Sin vhost webmail (Roundcube no instalado o dominio sin webmail)">—</span>'
        : '<span class="badge badge-status-pending" title="' . fresk_h($host) . ' solo HTTP: los navegadores con HSTS lo bloquean">HTTP</span>';
    if ($st === null) return $badge;
    return $badge . ' <form method="post" class="d-inline" onsubmit="return confirm(\'¿Emitir certificado Let\\\'s Encrypt para ' . fresk_h($host) . '? Su registro A debe apuntar a este servidor.\');">'
        . fresk_csrf_field()
        . '<input type="hidden" name="action" value="webmail_ssl"><input type="hidden" name="domain" value="' . fresk_h($dom) . '">'
        . '<button type="submit" class="btn btn-sm btn-outline-success" title="Emitir certificado para ' . fresk_h($host) . '"><i class="bi bi-shield-lock"></i> Webmail HTTPS</button></form>';
}
