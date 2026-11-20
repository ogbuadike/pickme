<?php
declare(strict_types=1);

/**
 * Push notification helpers (library, not an endpoint).
 * Uses the FCM HTTP v1 sender in unique/pm_fcm.php — no server keys in code.
 */

if (isset($_SERVER['SCRIPT_FILENAME']) && realpath((string)$_SERVER['SCRIPT_FILENAME']) === __FILE__) {
    http_response_code(404);
    exit;
}

require_once __DIR__ . '/security.php';
require_once __DIR__ . '/../unique/pm_fcm.php';

/**
 * Credit alert to every device of $uid. Payload keys are unchanged from the
 * previous implementation so the Flutter router keeps working.
 */
function credit_alert_app(float $amount, string $uid, bool $isInApp = false): int
{
    $title = 'Credit Alert';
    $body = "You've just received ₦" . number_format($amount, 2) . ' in your Pick Me wallet.';
    return pm_push_to_user(pm_db(), $uid, $title, $body, [
        'type'         => 'credit_alert',
        'title'        => $title,
        'body'         => $body,
        'is_inapp'     => $isInApp ? 'true' : 'false',
        'click_action' => 'transaction_page',
        'key2'         => 'transaction',
    ], $isInApp);
}

/** Generic ride/status push (best effort). */
function pm_push_ride_update(string $uid, string $title, string $body, array $data = []): int
{
    return pm_push_to_user(pm_db(), $uid, $title, $body, $data + ['type' => 'ride_update', 'click_action' => 'ride_history']);
}
