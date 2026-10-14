<?php
/**
 * Flesk Mini: límites de la edición de prueba gratuita.
 * 1 dominio · 1 cuenta de correo · 1 certificado SSL · 1 base de datos · 1 usuario SFTP/FTP.
 * Se comprueban aquí (antes de llamar al motor) y otra vez en el motor (lib/limits.sh), que es la barrera real.
 */
declare(strict_types=1);

const FLESK_MINI_MAX = 1;
const FLESK_MINI_SITE = 'https://serverflesk.es';
const FLESK_MINI_REGISTER = 'https://serverflesk.es/#ediciones';

/** Recurso => tabla del panel. */
function fresk_mini_tables(): array {
    return ['domain' => 'domains', 'mail' => 'mailboxes', 'ssl' => 'ssl_certs', 'db' => '`databases`', 'sftp' => 'sftp_users'];
}

/** Recursos usados (null si no se puede consultar). */
function fresk_mini_count(string $res): ?int {
    $t = fresk_mini_tables()[$res] ?? null;
    if ($t === null) return null;
    try {
        return (int)fresk_pdo()->query('SELECT COUNT(*) FROM ' . $t)->fetchColumn();
    } catch (Throwable $e) {
        return null;
    }
}

function fresk_mini_full(string $res): bool {
    $n = fresk_mini_count($res);
    return $n !== null && $n >= FLESK_MINI_MAX;
}

function fresk_mini_limit_message(): string {
    return t('mini.limit_msg');
}

/** Devuelve mensaje si la orden crearía un segundo recurso; null si se permite. */
function fresk_mini_precheck(string $group, string $sub): ?string {
    $adds = ['domain' => ['add'], 'mail' => ['add'], 'db' => ['add', 'create'], 'sftp' => ['add']];
    if (!in_array($sub, $adds[$group] ?? [], true)) return null;
    // Idempotencia: el motor acepta repetir el alta del mismo recurso; aquí solo se corta si ya hay uno y es otro.
    return fresk_mini_full($group) ? fresk_mini_limit_message() : null;
}

/** Tarjeta de promoción (dashboard). */
function fresk_mini_promo_html(): string {
    return '<div class="card fresk-card fresk-mini-promo mb-4"><div class="card-body d-flex flex-wrap gap-3 align-items-center">'
        . '<i class="bi bi-rocket-takeoff fs-2 text-success"></i>'
        . '<div class="flex-grow-1" style="min-width:240px">'
        . '<h2 class="h6 mb-1">' . te('mini.promo_title') . '</h2>'
        . '<ul class="small text-muted mb-0 ps-3">'
        . '<li>' . te('mini.promo_free') . '</li>'
        . '<li>' . te('mini.promo_paid') . '</li>'
        . '</ul></div>'
        . '<div class="d-flex flex-wrap gap-2">'
        . '<a class="btn btn-fresk-primary btn-sm" href="' . fresk_h(FLESK_MINI_REGISTER) . '" target="_blank" rel="noopener"><i class="bi bi-person-plus me-1"></i>' . te('mini.promo_register') . '</a>'
        . '<a class="btn btn-outline-secondary btn-sm" href="' . fresk_h(FLESK_MINI_SITE) . '" target="_blank" rel="noopener"><i class="bi bi-box-arrow-up-right me-1"></i>serverflesk.es</a>'
        . '</div></div></div>';
}

/** Aviso discreto en la página de un recurso cuando ya se usó el único permitido. */
function fresk_mini_limit_notice(string $res): string {
    if (!fresk_mini_full($res)) return '';
    return '<div class="alert alert-info d-flex gap-2 align-items-start small" role="status"><i class="bi bi-info-circle"></i><div>'
        . te('mini.limit_reached') . ' <a href="' . fresk_h(FLESK_MINI_REGISTER) . '" target="_blank" rel="noopener">' . te('mini.promo_more') . '</a></div></div>';
}
