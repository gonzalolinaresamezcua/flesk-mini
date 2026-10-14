<?php
/**
 * Flesk i18n: paquetes en web/lang/<code>.php (arrays clave => texto).
 * Español por defecto (config PANEL_LANG, si no "es"); Inglés instalado.
 * Preferencia por admin en admins.language + sesión.
 */
declare(strict_types=1);

const FRESK_LANG_FALLBACK = 'es';

function fresk_lang_dir(): string {
    return dirname(__DIR__, 2) . '/lang';
}

/** @return array<string,string> code => nombre nativo */
function fresk_available_langs(): array {
    static $langs = null;
    if ($langs !== null) return $langs;
    $langs = [];
    foreach (glob(fresk_lang_dir() . '/*.php') ?: [] as $f) {
        $code = basename($f, '.php');
        if (!preg_match('/^[a-z]{2}$/', $code)) continue;
        $pack = fresk_lang_pack($code);
        $langs[$code] = (string)($pack['_name'] ?? $code);
    }
    if ($langs === []) {
        $langs = [FRESK_LANG_FALLBACK => 'Español'];
    }
    // Español primero
    uksort($langs, static fn($a, $b) => ($a === 'es' ? -1 : ($b === 'es' ? 1 : strcmp($a, $b))));
    return $langs;
}

/** @return array<string,string> */
function fresk_lang_pack(string $code): array {
    static $packs = [];
    if (isset($packs[$code])) return $packs[$code];
    $packs[$code] = [];
    if (preg_match('/^[a-z]{2}$/', $code)) {
        $f = fresk_lang_dir() . '/' . $code . '.php';
        if (is_readable($f)) {
            $data = require $f;
            if (is_array($data)) $packs[$code] = $data;
        }
    }
    return $packs[$code];
}

function fresk_lang_valid(string $code): bool {
    return isset(fresk_available_langs()[$code]);
}

function fresk_default_lang(): string {
    try {
        $c = strtolower(trim((string)(fresk_cfg()['PANEL_LANG'] ?? '')));
    } catch (Throwable $e) {
        $c = '';
    }
    return ($c !== '' && fresk_lang_valid($c)) ? $c : FRESK_LANG_FALLBACK;
}

function fresk_lang(): string {
    $s = (string)($_SESSION['fresk_lang'] ?? '');
    return ($s !== '' && fresk_lang_valid($s)) ? $s : fresk_default_lang();
}

function fresk_set_session_lang(string $code): bool {
    if (!fresk_lang_valid($code)) return false;
    $_SESSION['fresk_lang'] = $code;
    return true;
}

function fresk_t_has(string $key): bool {
    return isset(fresk_lang_pack(fresk_lang())[$key]) || isset(fresk_lang_pack(FRESK_LANG_FALLBACK)[$key]);
}

/** Traduce una clave; admite argumentos estilo sprintf. */
function t(string $key, string|int ...$args): string {
    $pack = fresk_lang_pack(fresk_lang());
    $s = $pack[$key] ?? fresk_lang_pack(FRESK_LANG_FALLBACK)[$key] ?? $key;
    return $args ? vsprintf($s, $args) : $s;
}

/** Traducción escapada para HTML. */
function te(string $key, string|int ...$args): string {
    return fresk_h(t($key, ...$args));
}
