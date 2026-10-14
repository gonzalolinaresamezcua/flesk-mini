<?php
declare(strict_types=1);
require __DIR__ . '/auth.php';
if (!empty($_SESSION['fresk_admin_id'])) fresk_sgbd_drop_session_users(); // credenciales efímeras de Adminer
fresk_logout();
$base = rtrim((string)(fresk_cfg()['PANEL_BASE_PATH'] ?? '/flesk'), '/');
header('Location: ' . $base . '/login.php');
exit;
