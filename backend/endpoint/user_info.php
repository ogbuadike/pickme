<?php
declare(strict_types=1);

/**
 * POST user_info.php — the session user's profile (session required; `user` param must match or 403).
 *
 * No action                      → profile (only the session user's data; never hashes)
 * action=update_emergency_contact  emergency_contact
 * action=update_password           old_password, new_password (revokes the user's other sessions)
 * action=update_transaction_code   old_transaction_code, new_transaction_code (4–6 digits, rate limited)
 * action=update_profile_picture    multipart profile_picture (re-encoded to WebP)
 * action=delete_account            password (same as account_delete.php)
 */

require_once __DIR__ . '/security.php';
require_once __DIR__ . '/activities.php';

$uid = pm_require_session(['user' => []]);
$in = pm_input();
$action = pm_in_str($in, 'action', 40);

function ui_fail(string $message, string $code = 'VALIDATION'): void
{
    pm_error($code, $message, 200, ['error_msg' => $message]);
}

if ($action !== '') {
    pm_require_method('POST');
}

switch ($action) {
    case '':
        break;

    case 'delete_account':
        pm_json(pm_account_delete($uid, pm_in_raw($in, 'password', 1024)));
        break;

    case 'update_emergency_contact':
        $emergency = pm_in_str($in, 'emergency_contact', 100);
        if ($emergency !== '' && pm_normalize_phone($emergency) === '') {
            ui_fail('Please enter a valid phone number for your emergency contact.');
        }
        pm_exec('UPDATE unique_user_table SET emergency_contact = ? WHERE u_uid = ? LIMIT 1', 'ss', [$emergency !== '' ? pm_normalize_phone($emergency) : '', $uid]);
        pm_json(['error' => false, 'message' => 'Emergency contact updated successfully!']);
        break;

    case 'update_password':
        pm_rate_limit('pwd_change', $uid, 5, 900, 'Too many attempts. Please wait 15 minutes.');
        $old = pm_in_raw($in, 'old_password', 1024);
        $new = pm_in_raw($in, 'new_password', 1024);
        if (strlen($new) < 8 || strlen($new) > 128) {
            ui_fail('New password must be between 8 and 128 characters.');
        }
        $row = pm_q_one('SELECT pass_code FROM unique_user_table WHERE u_uid = ? LIMIT 1', 's', [$uid]);
        [$ok] = pm_password_check($old, (string)($row['pass_code'] ?? ''));
        if (!$ok) {
            ui_fail('Old password is incorrect.');
        }
        pm_tx(function () use ($uid, $new) {
            pm_exec('UPDATE unique_user_table SET pass_code = ?, reset = 0 WHERE u_uid = ? LIMIT 1', 'ss', [pm_password_hash($new), $uid]);
            pm_session_revoke_all($uid, 'password_change', (int)pm_current_session()['id']);
        });
        pm_rate_limit_clear('pwd_change', $uid);
        pm_activity($uid, 'Password changed');
        pm_json(['error' => false, 'message' => 'Password updated successfully!']);
        break;

    case 'update_transaction_code':
        pm_rate_limit('pin_change', $uid, 5, 900, 'Too many attempts. Please wait 15 minutes.');
        $oldCode = pm_in_raw($in, 'old_transaction_code', 16);
        $newCode = pm_in_raw($in, 'new_transaction_code', 16);
        if (!pm_valid_pin($newCode)) {
            ui_fail('Transaction code must be 4 to 6 digits.');
        }
        $row = pm_q_one('SELECT access FROM unique_user_table WHERE u_uid = ? LIMIT 1', 's', [$uid]);
        [$ok] = pm_password_check($oldCode, (string)($row['access'] ?? ''));
        if (!$ok) {
            ui_fail('Old transaction code is incorrect.');
        }
        pm_exec('UPDATE unique_user_table SET access = ? WHERE u_uid = ? LIMIT 1', 'ss', [pm_password_hash($newCode), $uid]);
        pm_rate_limit_clear('pin_change', $uid);
        pm_activity($uid, 'Transaction code changed');
        pm_json(['error' => false, 'message' => 'Transaction code updated successfully!']);
        break;

    case 'update_profile_picture':
        pm_rate_limit('avatar_upload', $uid, 10, 3600);
        $old = pm_q_one('SELECT b_logo FROM unique_user_table WHERE u_uid = ? LIMIT 1', 's', [$uid]);
        try {
            $url = pm_store_image('profile_picture', 'img/users/' . pm_uid_dir($uid), true, 5 * 1024 * 1024, 1024, 0);
        } catch (PmHttpError $e) {
            ui_fail($e->getMessage());
        }
        pm_exec('UPDATE unique_user_table SET b_logo = ? WHERE u_uid = ? LIMIT 1', 'ss', [$url, $uid]);
        if ($old && $old['b_logo'] !== $url) {
            pm_delete_stored_file((string)$old['b_logo']);
        }
        pm_json(['error' => false, 'message' => 'Profile picture updated successfully!', 'user_logo' => $url]);
        break;

    default:
        ui_fail('Invalid action');
}

// ---------------------------------------------------------------------------
// GET USER INFO (session user only)
// ---------------------------------------------------------------------------
$user = pm_q_one(
    'SELECT fname, lname, oname, email, phone, bal, base_location, last_location, country, b_logo, datetime,
            emergency_contact, visibility, Bank_Name, Account_Name, Account_Number, user_mode
     FROM unique_user_table WHERE u_uid = ? LIMIT 1',
    's',
    [$uid]
);
if ($user === null) {
    pm_error('NOT_FOUND', 'Invalid user ID', 200, ['error_msg' => 'Invalid user ID', 'user' => []]);
}

$driver = pm_driver_for_user($uid);
$totalTrips = ($driver !== null && $driver['id'] !== null) ? (int)$driver['completed_trips'] : 0;

$last = pm_q_one('SELECT amount, type FROM unique_account_table WHERE user_uid = ? ORDER BY id DESC LIMIT 1', 's', [$uid]);
$lastTran = '+0.00';
if ($last && is_numeric($last['amount'])) {
    $sign = ($last['type'] ?? 'minus') === 'plus' ? '+' : '-';
    $amt = number_format((float)$last['amount'], 2, '.', '');
    $lastTran = ($amt === '0.00') ? '+0.00' : $sign . $amt;
}

$privacyUrl = 'https://realpickme.com/endpoint/privacy';
$setting = pm_q_one("SELECT setting_value FROM app_settings WHERE setting_key = 'privacy_policy_url' LIMIT 1");
if ($setting) {
    $privacyUrl = (string)$setting['setting_value'];
}

pm_json([
    'error' => false,
    'user'  => [
        'user_fname'           => (string)$user['fname'],
        'user_bal'             => (string)($user['bal'] ?? '0.00'),
        'user_lname'           => (string)$user['lname'],
        'user_oname'           => (string)$user['oname'],
        'user_email'           => (string)$user['email'],
        'user_phone'           => (string)$user['phone'],
        'user_base_location'   => (string)$user['base_location'],
        'user_last_location'   => (string)$user['last_location'],
        'user_country'         => (string)$user['country'],
        'user_logo'            => (string)$user['b_logo'],
        'user_date_registered' => (string)$user['datetime'],
        'emergency_contact'    => (string)($user['emergency_contact'] ?? ''),
        'user_approved_user'   => (string)$user['visibility'],
        'user_last_tran'       => $lastTran,
        'user_currency'        => '₦',
        'user_bank'            => (string)$user['Bank_Name'],
        'user_account_name'    => (string)$user['Account_Name'],
        'user_account_number'  => (string)$user['Account_Number'],
        'user_mode'            => (string)$user['user_mode'],
        'total_trips'          => $totalTrips,
    ],
    'app_settings' => ['privacy_policy_url' => $privacyUrl],
]);
