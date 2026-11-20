<?php
declare(strict_types=1);

/**
 * POST logout.php — revokes the current session (contract §6). Session required.
 * all=1      revoke every session of the user (all devices)
 * token=...  optional FCM device token to unbind from this account (stops pushes to this device)
 */

require_once __DIR__ . '/security.php';

pm_require_method('POST');
$uid = pm_require_session();
$in = pm_input();
$session = pm_current_session();

$all = in_array(strtolower(pm_in_str($in, 'all', 5)), ['1', 'true', 'yes'], true);
if ($all) {
    $revoked = pm_session_revoke_all($uid, 'logout_all');
} else {
    pm_session_revoke_id((int)$session['id'], 'logout');
    $revoked = 1;
}

$fcmToken = pm_clean_text($in['token'] ?? ($in['fcm_token'] ?? ''), 4096);
if ($fcmToken !== '') {
    pm_exec("UPDATE app_users SET uid = '' WHERE uid = ? AND u_token = ?", 'ss', [$uid, $fcmToken]);
} elseif ($all) {
    pm_exec("UPDATE app_users SET uid = '' WHERE uid = ?", 's', [$uid]);
}

unset($GLOBALS['PM_SESSION']);
pm_json(['error' => false, 'message' => $all ? 'Signed out of all devices.' : 'Signed out.', 'data' => ['revoked_sessions' => $revoked]]);
