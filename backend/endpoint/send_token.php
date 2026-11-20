<?php
declare(strict_types=1);

/**
 * POST send_token.php — register an FCM device token. PUBLIC (app key) per contract §5.
 * Params: token (FCM registration token), device (device info JSON), uid (ignored for binding).
 * The token is bound to a user ONLY when a valid X-Session-Token is presented (the user is taken
 * from the session, never from `uid`); without a session the device is stored anonymously.
 */

require_once __DIR__ . '/security.php';

pm_require_method('POST');
pm_require_app_key();
$in = pm_input();

pm_rate_limit('send_token_ip', pm_client_ip(), 60, 60);

$sessionUid = pm_optional_session_uid();
$claimedUid = pm_in_str($in, 'uid', 64);
if ($sessionUid !== '' && $claimedUid !== '' && !hash_equals($sessionUid, $claimedUid)) {
    pm_error('FORBIDDEN', 'You are not allowed to act on behalf of another account.', 403, ['data' => null]);
}

$token = pm_clean_text($in['token'] ?? '', 4096);
$device = pm_clean_text($in['device'] ?? '', 4000);
if ($token === '' || $device === '') {
    pm_error('VALIDATION', 'Token and device info are required', 200, ['data' => null]);
}
if (!preg_match('/^[A-Za-z0-9_:\-\.]{20,4096}$/', $token)) {
    pm_error('VALIDATION', 'Invalid device token', 200, ['data' => null]);
}
$deviceHash = hash('sha256', $device);

$row = pm_q_one('SELECT id, uid, u_token FROM app_users WHERE device_hash = ? ORDER BY id DESC LIMIT 1', 's', [$deviceHash]);
if ($row !== null) {
    $newUid = $sessionUid !== '' ? $sessionUid : (string)$row['uid'];
    if ($sessionUid === '' && $row['u_token'] !== $token) {
        $newUid = ''; // a different app install without a session must not inherit the old binding
    }
    if ($row['u_token'] === $token && $row['uid'] === $newUid) {
        pm_json(['error' => false, 'message' => 'No changes detected. Token and UID are the same.', 'data' => null]);
    }
    pm_exec('UPDATE app_users SET u_token = ?, uid = ?, date_time = NOW() WHERE id = ?', 'ssi', [$token, $newUid, (int)$row['id']]);
    $message = 'Device token and UID updated successfully';
} else {
    pm_exec(
        'INSERT INTO app_users (uid, u_token, device_info, device_hash, date_time) VALUES (?, ?, ?, ?, NOW())',
        'ssss',
        [$sessionUid, $token, $device, $deviceHash]
    );
    $message = 'Device logged successfully';
}

// The same FCM token must not stay bound to another account (e.g. shared phone, re-login).
pm_exec("UPDATE app_users SET uid = '' WHERE u_token = ? AND device_hash <> ?", 'ss', [$token, $deviceHash]);

pm_json(['error' => false, 'message' => $message, 'data' => null]);
