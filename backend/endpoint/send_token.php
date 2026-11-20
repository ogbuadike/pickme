<?php
declare(strict_types=1);

/**
 * POST send_token.php — register an FCM device token. PUBLIC (app key) per contract §5.
 * Params: token (FCM registration token), install_id (stable per app install; also read from the
 *         `device` JSON's install_id), device (device info JSON), uid (optional; must equal the session user).
 *
 * Devices are keyed by (install_id, session user). The token is bound to a user ONLY when a valid
 * X-Session-Token is presented — the user always comes from the session, never from `uid`. The same
 * install/token is unbound from any other account so pushes can never reach a previous user.
 * Requests without install_id fall back to a hash of the device JSON (older builds).
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
if ($token === '' || !preg_match('/^[A-Za-z0-9_:\-\.]{20,4096}$/', $token)) {
    pm_error('VALIDATION', 'A valid device token is required', 422, ['data' => null]);
}

$installId = pm_in_str($in, 'install_id', 64);
if ($installId === '' && $device !== '') {
    $decoded = json_decode($device, true);
    if (is_array($decoded) && isset($decoded['install_id']) && is_scalar($decoded['install_id'])) {
        $installId = pm_clean_text($decoded['install_id'], 64);
    }
}
if ($installId !== '' && !preg_match('/^[A-Za-z0-9_\-:.]{8,64}$/', $installId)) {
    pm_error('VALIDATION', 'Invalid install_id', 422, ['data' => null]);
}
$deviceHash = $device !== '' ? hash('sha256', $device) : null;
if ($installId === '' && $deviceHash === null) {
    pm_error('VALIDATION', 'install_id is required', 422, ['data' => null]);
}

$message = pm_tx(function () use ($sessionUid, $token, $device, $installId, $deviceHash): string {
    if ($installId !== '') {
        $row = pm_q_one('SELECT id, uid, u_token FROM app_users WHERE install_id = ? AND uid = ? LIMIT 1 FOR UPDATE', 'ss', [$installId, $sessionUid]);
    } else {
        $row = pm_q_one('SELECT id, uid, u_token FROM app_users WHERE install_id IS NULL AND device_hash = ? AND uid = ? ORDER BY id DESC LIMIT 1 FOR UPDATE', 'ss', [$deviceHash, $sessionUid]);
    }
    if ($row !== null) {
        if ($row['u_token'] === $token) {
            $msg = 'No changes detected. Token and UID are the same.';
            pm_exec('UPDATE app_users SET date_time = NOW() WHERE id = ?', 'i', [(int)$row['id']]);
        } else {
            pm_exec('UPDATE app_users SET u_token = ?, device_info = ?, device_hash = ?, date_time = NOW() WHERE id = ?', 'sssi', [$token, $device, $deviceHash, (int)$row['id']]);
            $msg = 'Device token and UID updated successfully';
        }
        $id = (int)$row['id'];
    } else {
        $id = pm_insert(
            'INSERT INTO app_users (uid, u_token, device_info, device_hash, install_id, date_time) VALUES (?, ?, ?, ?, ?, NOW())',
            'sssss',
            [$sessionUid, $token, $device, $deviceHash, $installId !== '' ? $installId : null]
        );
        $msg = 'Device logged successfully';
    }
    // This install / token must not stay bound to any other account (shared phone, re-login).
    if ($installId !== '') {
        pm_exec('DELETE FROM app_users WHERE id <> ? AND (install_id = ? OR u_token = ?)', 'iss', [$id, $installId, $token]);
    } else {
        pm_exec('DELETE FROM app_users WHERE id <> ? AND u_token = ?', 'is', [$id, $token]);
    }
    return $msg;
});

pm_json(['error' => false, 'message' => $message, 'data' => null]);
