<?php
declare(strict_types=1);

/**
 * POST set_pin.php — set the session user's transaction PIN (session required). Params: pin (4–6 digits).
 * Allowed when no PIN exists yet, or within 15 minutes of a fresh password login (e.g. after
 * reinstalling the app). Otherwise use user_info.php action=update_transaction_code.
 * Stored with password_hash (argon2id/bcrypt). Rate limited.
 */

require_once __DIR__ . '/security.php';
require_once __DIR__ . '/activities.php';

const SET_PIN_FRESH_LOGIN_SEC = 900;

pm_require_method('POST');
$uid = pm_require_session();
$in = pm_input();

pm_rate_limit('set_pin', $uid, 5, 3600, 'Too many attempts. Please try again later.');

$pin = pm_in_raw($in, 'pin', 16);
if ($pin === '') {
    pm_error('VALIDATION', "Pin can't be empty", 200, ['data' => null]);
}
if (!pm_valid_pin($pin)) {
    pm_error('VALIDATION', 'PIN must be 4 to 6 digits.', 200, ['data' => null]);
}

$row = pm_q_one('SELECT access FROM unique_user_table WHERE u_uid = ? LIMIT 1', 's', [$uid]);
$hasPin = trim((string)($row['access'] ?? '')) !== '';
$session = pm_current_session();
if ($hasPin && (int)($session['age_sec'] ?? PHP_INT_MAX) > SET_PIN_FRESH_LOGIN_SEC) {
    pm_error('CONFLICT', 'A PIN is already set. Sign in again or change it from your profile.', 200, ['data' => null]);
}

pm_exec('UPDATE unique_user_table SET access = ? WHERE u_uid = ? LIMIT 1', 'ss', [pm_password_hash($pin), $uid]);
pm_activity($uid, $hasPin ? 'Transaction PIN reset after login' : 'Transaction PIN set');

pm_json(['error' => false, 'message' => 'Pin set successfully.']);
