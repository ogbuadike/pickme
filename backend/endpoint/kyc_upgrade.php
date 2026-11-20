<?php
declare(strict_types=1);

/**
 * POST kyc_upgrade.php — KYC upgrade for the session user (session required). action=create_kyc
 * Params: phone, address, state, country, postal_code, bvn (11 digits), selfie_image (multipart).
 * Provider credentials come from the .env: FLW_SECRET_KEY, UFITPAY_API_KEY, UFITPAY_API_TOKEN,
 * BVN_CONSENT_REDIRECT_URL. Upstream raw responses are not echoed to the client.
 */

require_once __DIR__ . '/security.php';
require_once __DIR__ . '/activities.php';

pm_require_method('POST');
$uid = pm_require_session();
$in = pm_input();

function kyc_api(string $url, string $method, array $data, array $headers): array
{
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CUSTOMREQUEST  => $method,
        CURLOPT_HTTPHEADER     => $headers,
        CURLOPT_CONNECTTIMEOUT => 5,
        CURLOPT_TIMEOUT        => 20,
        CURLOPT_SSL_VERIFYPEER => true,
    ]);
    if ($method !== 'GET') {
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($data));
    }
    $resp = curl_exec($ch);
    $err = curl_error($ch);
    curl_close($ch);
    if ($err !== '' || !is_string($resp)) {
        return ['error' => true];
    }
    $decoded = json_decode($resp, true);
    return is_array($decoded) ? $decoded : ['error' => true];
}

if (pm_in_str($in, 'action', 40) !== 'create_kyc') {
    pm_error('VALIDATION', 'Invalid action', 400, ['data' => []]);
}
pm_rate_limit('kyc', $uid, 5, 86400, 'Too many KYC attempts today. Please try again tomorrow.');

foreach (['phone', 'address', 'state', 'country', 'postal_code', 'bvn'] as $f) {
    if (pm_in_str($in, $f, 255) === '') {
        pm_error('VALIDATION', 'Missing ' . $f, 400, ['data' => []]);
    }
}
$bvn = pm_in_str($in, 'bvn', 11);
if (!preg_match('/^\d{11}$/', $bvn)) {
    pm_error('VALIDATION', 'Invalid BVN', 400, ['data' => []]);
}
$phone = pm_normalize_phone(pm_in_str($in, 'phone', 32));
if ($phone === '') {
    pm_error('VALIDATION', 'Invalid phone number', 400, ['data' => []]);
}

$user = pm_q_one('SELECT fname, lname, email, account FROM unique_user_table WHERE u_uid = ? LIMIT 1', 's', [$uid]);
if ($user === null) {
    pm_error('NOT_FOUND', 'User not found', 404, ['data' => []]);
}

$flwKey = pm_env('FLW_SECRET_KEY', env_data('API_KEY_live'));
$ufitKey = pm_env('UFITPAY_API_KEY');
$ufitToken = pm_env('UFITPAY_API_TOKEN');
if ($flwKey === '' || $ufitKey === '' || $ufitToken === '') {
    pm_log('error', 'kyc providers not configured');
    pm_error('SERVER', 'KYC is temporarily unavailable.', 503, ['data' => []]);
}

$accountData = json_decode((string)$user['account'], true);
$orderRef = is_array($accountData) ? (string)($accountData['data']['order_ref'] ?? '') : '';
$vaUpdated = false;
if ($orderRef !== '') {
    $upd = kyc_api('https://api.flutterwave.com/v3/virtual-account-numbers/' . rawurlencode($orderRef), 'PUT', ['bvn' => $bvn], ['Authorization: Bearer ' . $flwKey, 'Content-Type: application/json']);
    $vaUpdated = ($upd['status'] ?? '') === 'success';
}

$consent = kyc_api('https://api.flutterwave.com/v3/bvn/verifications', 'POST', [
    'bvn'          => $bvn,
    'firstname'    => (string)$user['fname'],
    'lastname'     => (string)$user['lname'],
    'redirect_url' => pm_env('BVN_CONSENT_REDIRECT_URL', 'https://realpickme.com/bvnconsent'),
], ['Authorization: Bearer ' . $flwKey, 'Content-Type: application/json']);

try {
    $selfieUrl = pm_store_image('selfie_image', 'uploads/kyc/' . pm_uid_dir($uid), true, 8 * 1024 * 1024, 1600, 300);
} catch (PmHttpError $e) {
    pm_error('VALIDATION', $e->getMessage(), 400, ['data' => []]);
}

$ufit = kyc_api('https://api.ufitpay.com/v1/create_card_holder', 'POST', [
    'first_name'   => (string)$user['fname'],
    'last_name'    => (string)$user['lname'],
    'email'        => (string)$user['email'],
    'phone'        => $phone,
    'address'      => pm_in_str($in, 'address', 255),
    'state'        => pm_in_str($in, 'state', 100),
    'country'      => pm_in_str($in, 'country', 100),
    'postal_code'  => pm_in_str($in, 'postal_code', 20),
    'kyc_method'   => 'SELFIE_IMAGE',
    'bvn'          => $bvn,
    'selfie_image' => $selfieUrl,
], ['Api-Key: ' . $ufitKey, 'Api-Token: ' . $ufitToken, 'Content-Type: application/json']);

if (empty($ufit['data']) || !is_array($ufit['data'])) {
    pm_log('warning', 'kyc card holder creation failed');
    pm_error('SERVER', 'KYC creation failed. Please try again later.', 502, ['data' => []]);
}
pm_activity($uid, 'KYC submitted');

$cardHolder = array_intersect_key($ufit['data'], array_flip(['id', 'card_holder_id', 'status', 'first_name', 'last_name', 'kyc_status', 'created_at']));
pm_json([
    'error'   => false,
    'message' => 'KYC created successfully. Please complete BVN verification by following the provided URL.',
    'data'    => [
        'virtual_account' => ['status' => $vaUpdated ? 'success' : 'skipped'],
        'card_holder'     => $cardHolder,
        'bvn_consent'     => [
            'consent_reference' => $consent['data']['reference'] ?? null,
            'redirect_url'      => $consent['data']['redirect_url'] ?? null,
        ],
    ],
], 201);
