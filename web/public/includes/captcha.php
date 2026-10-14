<?php
/**
 * Flesk: captcha deslizante (arrastra la pieza hasta el hueco). Sin servicios externos.
 * Validación en servidor: token de un solo uso por sesión, caduca a los 2 min,
 * |posición - objetivo| <= 6 px, duración >= 300 ms y trayectoria no perfectamente lineal.
 */
declare(strict_types=1);

const FRESK_CAPTCHA_W = 300;       // ancho del lienzo (px)
const FRESK_CAPTCHA_H = 90;        // alto del lienzo
const FRESK_CAPTCHA_PIECE = 44;    // lado de la pieza
const FRESK_CAPTCHA_TOL = 6;       // tolerancia (px)
const FRESK_CAPTCHA_TTL = 120;     // segundos
const FRESK_CAPTCHA_MIN_MS = 300;  // duración mínima del arrastre

/** Genera un reto nuevo (invalida el anterior). @return array{token:string,y:int} */
function fresk_captcha_new(): array {
    $x = random_int(80, FRESK_CAPTCHA_W - FRESK_CAPTCHA_PIECE - 8);
    $y = random_int(8, FRESK_CAPTCHA_H - FRESK_CAPTCHA_PIECE - 8);
    $token = bin2hex(random_bytes(16));
    $_SESSION['fresk_captcha'] = ['t' => $token, 'x' => $x, 'y' => $y, 'iat' => time(), 'seed' => random_int(1, PHP_INT_MAX)];
    return ['token' => $token, 'y' => $y];
}

/** Imagen SVG del reto (fondo de triángulos + hueco + señuelos). */
function fresk_captcha_svg(string $token): ?string {
    $c = $_SESSION['fresk_captcha'] ?? null;
    if (!is_array($c) || !hash_equals((string)$c['t'], $token) || time() - (int)$c['iat'] > FRESK_CAPTCHA_TTL) return null;
    mt_srand((int)$c['seed']);
    $W = FRESK_CAPTCHA_W; $H = FRESK_CAPTCHA_H; $P = FRESK_CAPTCHA_PIECE;
    $pal = ['#e6fbf5', '#bff0e2', '#8fdcc8', '#5fc4ad', '#d4f5ec', '#a9e6d6'];
    $s = '<svg xmlns="http://www.w3.org/2000/svg" width="' . $W . '" height="' . $H . '" viewBox="0 0 ' . $W . ' ' . $H . '">';
    $s .= '<rect width="100%" height="100%" fill="#f2fcf8"/>';
    for ($i = 0; $i < 22; $i++) {
        $pts = [];
        for ($k = 0; $k < 3; $k++) $pts[] = mt_rand(-30, $W + 30) . ',' . mt_rand(-30, $H + 30);
        $s .= '<polygon points="' . implode(' ', $pts) . '" fill="' . $pal[mt_rand(0, count($pal) - 1)] . '" opacity="0.' . mt_rand(35, 85) . '"/>';
    }
    // Señuelos: siluetas suaves que no son el hueco
    for ($i = 0; $i < 2; $i++) {
        $dx = mt_rand(10, $W - $P - 10); $dy = mt_rand(4, $H - $P - 4);
        if (abs($dx - (int)$c['x']) < $P + 8) continue;
        $s .= '<rect x="' . $dx . '" y="' . $dy . '" width="' . $P . '" height="' . $P . '" rx="9" fill="#ffffff" opacity="0.35"/>';
    }
    // Hueco
    $gx = (int)$c['x']; $gy = (int)$c['y'];
    $s .= '<rect x="' . $gx . '" y="' . $gy . '" width="' . $P . '" height="' . $P . '" rx="9" fill="#0f3d35" opacity="0.28"/>';
    $s .= '<rect x="' . ($gx + 1) . '" y="' . ($gy + 1) . '" width="' . ($P - 2) . '" height="' . ($P - 2) . '" rx="8" fill="none" stroke="#ffffff" stroke-width="2" opacity="0.9"/>';
    $s .= '</svg>';
    mt_srand();
    return $s;
}

/**
 * Verifica y CONSUME el reto (un solo uso, también si falla).
 * Espera POST: captcha_token, captcha_x (int), captcha_trace (JSON [[ms,x],...]).
 */
function fresk_captcha_verify(): bool {
    $c = $_SESSION['fresk_captcha'] ?? null;
    unset($_SESSION['fresk_captcha']);
    if (!is_array($c)) return false;
    $token = (string)($_POST['captcha_token'] ?? '');
    if ($token === '' || !hash_equals((string)$c['t'], $token)) return false;
    if (time() - (int)$c['iat'] > FRESK_CAPTCHA_TTL) return false;
    $x = filter_var($_POST['captcha_x'] ?? null, FILTER_VALIDATE_INT);
    if ($x === false || abs($x - (int)$c['x']) > FRESK_CAPTCHA_TOL) return false;
    $raw = (string)($_POST['captcha_trace'] ?? '');
    if (strlen($raw) > 20000) return false;
    $trace = json_decode($raw, true);
    if (!is_array($trace) || count($trace) < 5 || count($trace) > 600) return false;
    $ts = []; $xs = [];
    foreach ($trace as $p) {
        if (!is_array($p) || count($p) !== 2 || !is_numeric($p[0]) || !is_numeric($p[1])) return false;
        $ts[] = (float)$p[0]; $xs[] = (float)$p[1];
    }
    $n = count($ts);
    for ($i = 1; $i < $n; $i++) if ($ts[$i] < $ts[$i - 1]) return false;  // tiempo monótono
    if ($ts[$n - 1] - $ts[0] < FRESK_CAPTCHA_MIN_MS) return false;
    if (abs($xs[$n - 1] - $x) > 3) return false;                          // la traza termina donde se suelta
    // No perfectamente lineal: residuo máximo de la recta x(t) >= 1.5 px
    $mt = array_sum($ts) / $n; $mx = array_sum($xs) / $n;
    $num = 0.0; $den = 0.0;
    for ($i = 0; $i < $n; $i++) { $num += ($ts[$i] - $mt) * ($xs[$i] - $mx); $den += ($ts[$i] - $mt) ** 2; }
    if ($den <= 0) return false;
    $b = $num / $den; $a = $mx - $b * $mt;
    $maxRes = 0.0;
    for ($i = 0; $i < $n; $i++) $maxRes = max($maxRes, abs($xs[$i] - ($a + $b * $ts[$i])));
    return $maxRes >= 1.5;
}
