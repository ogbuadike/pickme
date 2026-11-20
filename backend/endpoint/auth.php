<?php
declare(strict_types=1);

/**
 * Backward-compatible wrapper. The app key (Authorization header) only identifies the
 * app build; user identity comes from pm_require_session() in security.php.
 * The accepted key hash(es) are configured with APP_KEY_SHA256 in the .env.
 */

if (isset($_SERVER['SCRIPT_FILENAME']) && realpath((string)$_SERVER['SCRIPT_FILENAME']) === __FILE__) {
    http_response_code(404);
    exit;
}

require_once __DIR__ . '/security.php';

function checkAuthorization($token): bool
{
    return pm_app_key_valid((string)$token);
}
