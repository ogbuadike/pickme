<?php
declare(strict_types=1);

/**
 * POST validate_pin.php — verify the session user's transaction PIN (session required). Params: pin.
 * Constant-time verification via password_verify; 5 wrong attempts per 15 minutes per user.
 */

require_once __DIR__ . '/security.php';

pm_require_method('POST');
$uid = pm_require_session();
$in = pm_input();

$pin = pm_in_raw($in, 'pin', 16);
if ($pin === '') {
    pm_error('VALIDATION', "Pin can't be empty", 200, ['data' => null]);
}

pm_rate_limit('validate_pin', $uid, 5, 900, 'Too many wrong PIN attempts. Please wait 15 minutes.');

$row = pm_q_one('SELECT access FROM unique_user_table WHERE u_uid = ? LIMIT 1', 's', [$uid]);
[$ok, $rehash] = pm_password_check($pin, (string)($row['access'] ?? ''));

if (!$ok) {
    pm_error('VALIDATION', 'Error Authenticating pin', 200);
}
if ($rehash) {
    pm_exec('UPDATE unique_user_table SET access = ? WHERE u_uid = ? LIMIT 1', 'ss', [pm_password_hash($pin), $uid]);
}
pm_rate_limit_clear('validate_pin', $uid);

pm_json(['error' => false, 'message' => 'Authenticated']);
