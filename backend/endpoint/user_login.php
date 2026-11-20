<?php
declare(strict_types=1);

/**
 * POST user_login.php — PUBLIC (app key only). Params: email (email or phone), password.
 * Success: login_msg contains the legacy profile fields + session_token + session_expires_at (contract §2).
 * Passwords: argon2id/bcrypt; legacy unsalted sha256 hashes are verified once and upgraded.
 * Rate limited per IP and per identifier.
 */

require_once __DIR__ . '/security.php';
require_once __DIR__ . '/activities.php';

pm_require_method('POST');
pm_require_app_key();
$in = pm_input();

function login_failure(string $title, string $body, string $code = 'VALIDATION', int $status = 200): void
{
    pm_error($code, $body, $status, ['login_msg' => ['title_msg' => $title, 'title_msg_body' => $body]]);
}

function getDriverLoginMeta(string $userUid): array
{
    $default = [
        'is_driver' => false, 'driver_status' => 'not_started', 'driver_id' => '', 'driver_online' => 0,
        'driver_rank' => '', 'driver_category' => '', 'driver_car_plate' => '', 'post_login_home' => 'home',
    ];
    $row = pm_driver_for_user($userUid);
    if ($row === null) {
        return $default;
    }
    $status = pm_normalize_driver_status((string)$row['onboarding_status']);
    $driverId = $row['id'] !== null ? (string)$row['id'] : (string)($row['onboarding_driver_id'] ?? '');
    $isDriver = $driverId !== '' && $status === 'activated';
    return [
        'is_driver'        => $isDriver,
        'driver_status'    => $status,
        'driver_id'        => $isDriver ? $driverId : '',
        'driver_online'    => $isDriver ? (int)$row['is_online'] : 0,
        'driver_rank'      => $isDriver ? (string)$row['rank'] : '',
        'driver_category'  => $isDriver ? (string)$row['category'] : '',
        'driver_car_plate' => $isDriver ? (string)$row['car_plate'] : '',
        'post_login_home'  => $isDriver ? 'driver_home' : 'home',
    ];
}

$identifier = pm_in_str($in, 'email', 255);
$password = pm_in_raw($in, 'password', 1024);

if ($identifier === '' || $password === '') {
    login_failure('Invalid Username or Password', 'Please enter your email/phone and password.');
}

$identKey = strtolower($identifier);
pm_rate_limit('login_ip', pm_client_ip(), 30, 300, 'Too many login attempts. Please wait a few minutes.');
pm_rate_limit('login_id', $identKey, 8, 900, 'Too many login attempts for this account. Please wait 15 minutes or reset your password.');

$candidates = pm_q_all(
    'SELECT u_uid, fname, lname, oname, email, phone, pass_code, sta, Account_Name, Account_Number, Bank_Name, user_mode, u_type
     FROM unique_user_table
     WHERE email = ? OR phone = ?
     LIMIT 3',
    'ss',
    [$identifier, $identifier]
);

$user = null;
$needsRehash = false;
foreach ($candidates as $c) {
    [$ok, $rehash] = pm_password_check($password, (string)$c['pass_code']);
    if ($ok) {
        $user = $c;
        $needsRehash = $rehash;
        break;
    }
}
if (!$candidates) {
    pm_password_check($password, ''); // equalise timing
}

if ($user === null || (int)$user['sta'] === 2) {
    login_failure('Invalid Username or Password', 'Oops! The username or password you entered is incorrect. Please double-check and try again.');
}
if ((int)$user['sta'] === 1) {
    login_failure('Account Suspended', 'Your account has been suspended. Please contact support for further assistance.', 'FORBIDDEN', 200);
}
if ((int)$user['sta'] !== 0) {
    login_failure('Invalid Username or Password', 'Oops! The username or password you entered is incorrect. Please double-check and try again.');
}

$uid = (string)$user['u_uid'];
if ($needsRehash) {
    pm_exec('UPDATE unique_user_table SET pass_code = ? WHERE u_uid = ? LIMIT 1', 'ss', [pm_password_hash($password), $uid]);
}
pm_rate_limit_clear('login_id', $identKey);

$session = pm_session_issue($uid);
$driverMeta = getDriverLoginMeta($uid);
pm_activity($uid, 'Logged in to account');

pm_json([
    'error' => false,
    'login_msg' => [
        'title_msg'          => 'Success!',
        'title_msg_body'     => 'Congratulations! You have successfully logged in to your account.',
        'uid'                => $uid,
        'fname'              => (string)$user['fname'],
        'lname'              => (string)$user['lname'],
        'oname'              => (string)$user['oname'],
        'email'              => (string)$user['email'],
        'phone'              => (string)$user['phone'],
        'accountname'        => (string)$user['Account_Name'],
        'accountnumber'      => (string)$user['Account_Number'],
        'bankname'           => (string)$user['Bank_Name'],
        'user_mode'          => (string)$user['user_mode'],
        'u_type'             => (string)$user['u_type'],
        'is_driver'          => $driverMeta['is_driver'],
        'driver_status'      => $driverMeta['driver_status'],
        'driver_id'          => $driverMeta['driver_id'],
        'driver_online'      => $driverMeta['driver_online'],
        'driver_rank'        => $driverMeta['driver_rank'],
        'driver_category'    => $driverMeta['driver_category'],
        'driver_car_plate'   => $driverMeta['driver_car_plate'],
        'post_login_home'    => $driverMeta['post_login_home'],
        'session_token'      => $session['session_token'],
        'session_expires_at' => $session['session_expires_at'],
    ],
]);
