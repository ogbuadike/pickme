<?php
declare(strict_types=1);

/**
 * Database connection for the Pick Me API.
 *
 * - Uses credentials from the .env (DATAUSER / DATAPASS / DATANAME, optional DATAHOST / DATAPORT).
 * - Throws on every SQL error (mysqli strict reporting); callers never see driver error text,
 *   the central exception handler in endpoint/security.php logs it and returns a generic envelope.
 * - No PHP sessions, cookies, redirects or HTML headers: this is a stateless JSON API.
 */

if (isset($_SERVER['SCRIPT_FILENAME']) && realpath((string)$_SERVER['SCRIPT_FILENAME']) === __FILE__) {
    http_response_code(404);
    exit;
}

require_once __DIR__ . '/unique_1.php';

mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);

if (!function_exists('pm_db_connect')) {
    function pm_db_connect(): mysqli
    {
        $host = env_data('DATAHOST');
        if ($host === '') {
            $host = 'localhost';
        }
        $port = (int)(env_data('DATAPORT') ?: 3306);

        $db = mysqli_init();
        $db->options(MYSQLI_OPT_CONNECT_TIMEOUT, 5);
        $db->real_connect($host, env_data('DATAUSER'), env_data('DATAPASS'), env_data('DATANAME'), $port);
        $db->set_charset('utf8mb4');
        return $db;
    }
}

$currency = '&#x20A6;';

try {
    $dbconn = pm_db_connect();
} catch (Throwable $e) {
    error_log('[pickme] database connection failed: ' . $e->getMessage());
    if (!headers_sent()) {
        http_response_code(503);
        header('Content-Type: application/json; charset=utf-8');
        header('Cache-Control: no-store');
        header('Retry-After: 5');
    }
    echo json_encode([
        'error'   => true,
        'code'    => 'SERVER',
        'message' => 'Service temporarily unavailable. Please try again.',
    ]);
    exit;
}
