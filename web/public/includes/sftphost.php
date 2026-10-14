<?php
/**
 * Flesk: host de conexión SFTP/FTP de un dominio, siempre utilizable.
 * 1) ftp.<dominio> si tiene registro A/AAAA público que apunta a este servidor
 * 2) si no, el propio <dominio> si apunta a este servidor
 * 3) si no, la IP pública del servidor (PUBLIC_IP de config.conf)
 * Flesk sirve SFTP por SSH (puerto 22): no depende de certificados TLS del nombre.
 */
declare(strict_types=1);
if (!function_exists('fresk_sftp_host')) {
function fresk_sftp_resolves(string $h): array {
    $ips = [];
    foreach ((@dns_get_record($h, DNS_A) ?: []) as $r) if (!empty($r['ip'])) $ips[] = $r['ip'];
    foreach ((@dns_get_record($h, DNS_AAAA) ?: []) as $r) if (!empty($r['ipv6'])) $ips[] = $r['ipv6'];
    return $ips;
}
/** @return array{host:string,source:string,ips:array,note:string} */
function fresk_sftp_host(string $domain): array {
    static $cache = [];
    $domain = strtolower(trim($domain, ". \t"));
    if (isset($cache[$domain])) return $cache[$domain];
    $ip = ''; $mine = [];
    try { $c = fresk_cfg(); $ip = (string)($c['PUBLIC_IP'] ?? ''); $mine = array_filter([$ip, (string)($c['PUBLIC_IP6'] ?? '')]); } catch (Throwable $e) {}
    // Solo vale un nombre que apunte a ESTE servidor (evita comodines/CNAME hacia otro host)
    $here = static fn(array $ips): bool => !$mine || (bool)array_intersect($ips, $mine);
    if ($domain !== '' && ($ips = fresk_sftp_resolves('ftp.' . $domain)) && $here($ips)) {
        $res = ['host' => 'ftp.' . $domain, 'source' => 'ftp', 'ips' => $ips, 'note' => ''];
    } elseif ($domain !== '' && ($ips = fresk_sftp_resolves($domain)) && $here($ips)) {
        $res = ['host' => $domain, 'source' => 'domain', 'ips' => $ips,
            'note' => 'ftp.' . $domain . ' no tiene registro DNS; se usa ' . $domain . ' (' . $ips[0] . '). Opcional: crea ftp A ' . $ips[0] . ' en el DNS.'];
    } else {
        $res = ['host' => $ip !== '' ? $ip : $domain, 'source' => 'ip', 'ips' => $ip !== '' ? [$ip] : [],
            'note' => 'Ni ftp.' . $domain . ' ni ' . $domain . ' apuntan a este servidor en DNS público; se usa la IP del servidor.'];
    }
    return $cache[$domain] = $res;
}
}
