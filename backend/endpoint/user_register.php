<?php
declare(strict_types=1);

/**
 * POST user_register.php — PUBLIC (app key only). Params: full_name, email, phone, password, device.
 * Creates the account (argon2id password), best-effort Flutterwave virtual account, and auto-logs-in:
 * login_msg.session_token / session_expires_at are returned (contract §2).
 * Rate limited per IP; duplicate email/phone rejected under a named lock (no double-submit race).
 */

require_once __DIR__ . '/security.php';
require_once __DIR__ . '/activities.php';

pm_require_method('POST');
pm_require_app_key();
$in = pm_input();

function reg_fail(string $body, string $code = 'VALIDATION'): void
{
    pm_error($code, $body, 200, ['login_msg' => ['title_msg' => 'Failed', 'title_msg_body' => $body]]);
}

pm_rate_limit('register_ip', pm_client_ip(), 10, 3600, 'Too many sign-up attempts. Please try again later.');

$fullName = pm_in_str($in, 'full_name', 120);
$email = strtolower(pm_in_str($in, 'email', 190));
$phone = pm_normalize_phone(pm_in_str($in, 'phone', 32));
$password = pm_in_raw($in, 'password', 1024);
$device = pm_clean_text($in['device'] ?? '', 2000);

if ($fullName === '' || $email === '' || $password === '' || pm_in_str($in, 'phone', 32) === '') {
    reg_fail('Full name, email, phone, and password are required.');
}
if (mb_strlen($fullName) < 3) {
    reg_fail('Please enter your full name.');
}
if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
    reg_fail('Please enter a valid email address.');
}
if ($phone === '') {
    reg_fail('Please enter a valid phone number.');
}
if (strlen($password) < 8 || strlen($password) > 128) {
    reg_fail('Password must be between 8 and 128 characters.');
}

$nameParts = preg_split('/\s+/', $fullName) ?: [$fullName];
$firstName = (string)array_shift($nameParts);
$lastName = trim(implode(' ', $nameParts));

$lockName = 'pm_reg_' . substr(hash('sha256', $email . '|' . $phone), 0, 40);
$lock = pm_q_one('SELECT GET_LOCK(?, 5) AS l', 's', [$lockName]);
if ((int)($lock['l'] ?? 0) !== 1) {
    reg_fail('Please try again in a moment.', 'CONFLICT');
}

try {
    $exists = pm_q_one('SELECT id FROM unique_user_table WHERE (email = ? OR phone = ?) AND sta <> 2 LIMIT 1', 'ss', [$email, $phone]);
    if ($exists) {
        reg_fail('A user with this email or phone number already exists.', 'CONFLICT');
    }

    do {
        $uid = pm_random_string(12);
    } while (pm_q_one('SELECT id FROM unique_user_table WHERE u_uid = ? LIMIT 1', 's', [$uid]) !== null);

    // Best-effort permanent virtual account (requires a configured BVN policy on the FLW account).
    $orderRef = $accountNumber = $bankName = '';
    $accountJson = '';
    $flwKey = pm_env('FLW_SECRET_KEY', env_data('API_KEY_live'));
    $vaBvn = pm_env('FLW_VA_BVN');
    if ($flwKey !== '' && $vaBvn !== '') {
        $ch = curl_init('https://api.flutterwave.com/v3/virtual-account-numbers');
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_POST           => true,
            CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_TIMEOUT        => 15,
            CURLOPT_HTTPHEADER     => ['Authorization: Bearer ' . $flwKey, 'Content-Type: application/json'],
            CURLOPT_POSTFIELDS     => json_encode([
                'email' => $email, 'is_permanent' => true, 'bvn' => $vaBvn, 'firstname' => $firstName,
                'lastname' => $lastName, 'phonenumber' => $phone, 'tx_ref' => $uid, 'narration' => $fullName,
            ]),
        ]);
        $resp = curl_exec($ch);
        curl_close($ch);
        $data = is_string($resp) ? json_decode($resp, true) : null;
        if (is_array($data) && ($data['status'] ?? '') === 'success' && !empty($data['data']['account_number'])) {
            $orderRef = (string)($data['data']['order_ref'] ?? '');
            $accountNumber = (string)$data['data']['account_number'];
            $bankName = (string)($data['data']['bank_name'] ?? '');
            $accountJson = (string)json_encode(['status' => 'success', 'data' => [
                'order_ref' => $orderRef, 'account_number' => $accountNumber, 'bank_name' => $bankName,
            ]]);
        } else {
            pm_log('warning', 'virtual account creation failed at registration');
        }
    }

    $now = pm_legacy_now();
    pm_exec(
        "INSERT INTO unique_user_table
            (u_uid, s_u_uid, link_id, bal, fname, lname, oname, email, phone, pass_code, base_location, last_location, country, sta, u_type,
             datetime, date, time, b_logo, visibility, career_switch, Account_URF, Account_Name, Account_Number, Bank_Name, AID,
             reset, access, account, us, ng, user_mode)
         VALUES (?, '', '', 0, ?, ?, '', ?, ?, ?, '', '', '', 0, 0, ?, ?, ?, '', 0, '', ?, ?, ?, ?, ?, 0, '', ?, '', '', '')",
        str_repeat('s', 15),
        [$uid, $firstName, $lastName, $email, $phone, pm_password_hash($password), $now['datetime'], $now['date'], $now['time'],
         $orderRef, $accountNumber !== '' ? $fullName : '', $accountNumber, $bankName, $device, $accountJson]
    );
} finally {
    pm_q_one('SELECT RELEASE_LOCK(?) AS r', 's', [$lockName]);
}

pm_activity($uid, 'Account registered');
$session = pm_session_issue($uid);

pm_json([
    'error' => false,
    'login_msg' => [
        'title_msg'          => 'Success',
        'title_msg_body'     => 'Registration successful',
        'uid'                => $uid,
        'session_token'      => $session['session_token'],
        'session_expires_at' => $session['session_expires_at'],
    ],
]);
