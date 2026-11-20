<?php
declare(strict_types=1);

/**
 * POST webhook.php — Flutterwave payment webhook (no app key / session; signature-verified, contract §5).
 *
 * 1. `verif-hash` header must equal FLW_SECRET_HASH (constant-time). Fail closed if not configured.
 * 2. The event is recorded in payment_events (UNIQUE provider+provider_tx_id) → retries/duplicates are idempotent.
 * 3. The transaction is re-verified with Flutterwave's API (amount, currency, tx_ref, status taken from the
 *    verification response, never from the webhook body).
 * 4. Wallet credit + fee debit + ledger rows + event status change happen in ONE transaction holding the
 *    payment_events row lock, so concurrent deliveries can never double-credit.
 * 5. Push + e-mail are sent after the response is flushed.
 */

require_once __DIR__ . '/security.php';
require_once __DIR__ . '/activities.php';

pm_require_method('POST');

$secretHash = pm_env('FLW_SECRET_HASH', env_data('SECRET_Hash_Webhook'));
if ($secretHash === '') {
    pm_log('error', 'webhook rejected: FLW_SECRET_HASH not configured');
    pm_error('SERVER', 'Webhook not configured', 503);
}
$signature = pm_header('verif-hash');
if ($signature === '' || !hash_equals($secretHash, $signature)) {
    pm_log('warning', 'webhook signature mismatch', ['ip' => pm_client_ip()]);
    pm_error('UNAUTHORIZED', 'Unauthorized access', 401, ['data' => null]);
}

$raw = (string)file_get_contents('php://input', false, null, 0, 262144);
$event = json_decode($raw, true);
if (!is_array($event) || !is_array($event['data'] ?? null)) {
    pm_error('VALIDATION', 'Invalid JSON payload', 400, ['data' => null]);
}
$txId = (string)($event['data']['id'] ?? '');
if ($txId === '' || !ctype_digit($txId)) {
    pm_error('VALIDATION', 'Missing transaction id', 400, ['data' => null]);
}

// Idempotency anchor.
pm_exec(
    "INSERT IGNORE INTO payment_events (provider, provider_tx_id, tx_ref, flw_ref, status, payload, created_at, updated_at)
     VALUES ('flutterwave', ?, ?, ?, 'received', ?, UTC_TIMESTAMP(), UTC_TIMESTAMP())",
    'ssss',
    [$txId, mb_substr((string)($event['data']['tx_ref'] ?? ''), 0, 128), mb_substr((string)($event['data']['flw_ref'] ?? ''), 0, 128), mb_substr($raw, 0, 65000)]
);
$existing = pm_q_one("SELECT id, status FROM payment_events WHERE provider = 'flutterwave' AND provider_tx_id = ?", 's', [$txId]);
if ($existing && in_array($existing['status'], ['processed', 'orphan', 'rejected'], true)) {
    pm_json(['status' => 'success', 'message' => 'Already processed', 'data' => null], 200);
}

// Server-side verification with Flutterwave.
$flwKey = pm_env('FLW_SECRET_KEY', env_data('API_KEY_live'));
if ($flwKey === '') {
    pm_log('error', 'webhook: FLW_SECRET_KEY not configured');
    pm_error('SERVER', 'Verification unavailable', 503);
}
$ch = curl_init(rtrim(pm_env('FLW_API_BASE', 'https://api.flutterwave.com'), '/') . '/v3/transactions/' . rawurlencode($txId) . '/verify');
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_CONNECTTIMEOUT => 5,
    CURLOPT_TIMEOUT        => 20,
    CURLOPT_HTTPHEADER     => ['Authorization: Bearer ' . $flwKey, 'Content-Type: application/json'],
    CURLOPT_SSL_VERIFYPEER => true,
]);
$resp = curl_exec($ch);
$httpCode = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
$curlErr = curl_error($ch);
curl_close($ch);
if (!is_string($resp) || $resp === '' || $curlErr !== '') {
    pm_log('error', 'webhook verify transport failure', ['http' => $httpCode]);
    pm_error('SERVER', 'Failed to verify transaction', 502); // non-2xx → Flutterwave retries
}
$verify = json_decode($resp, true);
$v = is_array($verify['data'] ?? null) ? $verify['data'] : [];
$verified = ($verify['status'] ?? '') === 'success' && ($v['status'] ?? '') === 'successful' && (string)($v['id'] ?? '') === $txId;
if (!$verified) {
    pm_exec("UPDATE payment_events SET status = 'rejected', updated_at = UTC_TIMESTAMP() WHERE provider = 'flutterwave' AND provider_tx_id = ?", 's', [$txId]);
    pm_json(['error' => true, 'code' => 'VALIDATION', 'message' => 'Transaction verification failed', 'data' => null], 200);
}

$amount = round((float)($v['amount'] ?? 0), 2);
$appFee = round(max(0.0, (float)($v['app_fee'] ?? 0)), 2);
$currency = strtoupper((string)($v['currency'] ?? ''));
$userUid = (string)($v['tx_ref'] ?? '');
$flwRef = (string)($v['flw_ref'] ?? '');
$paymentType = mb_substr((string)($v['payment_type'] ?? 'bank_transfer'), 0, 64);
$originator = trim((string)($v['meta']['originatorname'] ?? '') . ' ' . (string)($v['meta']['bankname'] ?? ''));

if ($amount <= 0 || $currency !== 'NGN' || $appFee > $amount) {
    pm_exec("UPDATE payment_events SET status = 'rejected', updated_at = UTC_TIMESTAMP() WHERE provider = 'flutterwave' AND provider_tx_id = ?", 's', [$txId]);
    pm_log('warning', 'webhook rejected: amount/currency', ['tx' => $txId, 'currency' => $currency]);
    pm_json(['error' => true, 'code' => 'VALIDATION', 'message' => 'Unsupported transaction', 'data' => null], 200);
}

$outcome = pm_tx(function () use ($txId, $userUid, $amount, $appFee, $flwRef, $paymentType, $originator, $resp) {
    $ev = pm_q_one("SELECT id, status FROM payment_events WHERE provider = 'flutterwave' AND provider_tx_id = ? FOR UPDATE", 's', [$txId]);
    if (!$ev || $ev['status'] === 'processed' || $ev['status'] === 'orphan') {
        return 'duplicate';
    }
    $user = pm_q_one('SELECT u_uid FROM unique_user_table WHERE u_uid = ? LIMIT 1 FOR UPDATE', 's', [$userUid]);
    if ($user === null) {
        pm_exec("UPDATE payment_events SET status = 'orphan', amount = ?, u_uid = ?, updated_at = UTC_TIMESTAMP() WHERE id = ?", 'dsi', [$amount, $userUid, (int)$ev['id']]);
        return 'orphan';
    }
    pm_wallet_credit($userUid, $amount);
    pm_ledger_add($userUid, $amount, 'plus', $originator !== '' ? $originator : 'Wallet funding', $flwRef !== '' ? $flwRef : 'FLW_' . $txId, $paymentType, 'successful', mb_substr($resp, 0, 60000), $txId);
    if ($appFee > 0) {
        if (!pm_wallet_debit($userUid, $appFee)) {
            throw new RuntimeException('fee debit failed after credit');
        }
        pm_ledger_add($userUid, $appFee, 'minus', 'Transfer charge', $flwRef !== '' ? $flwRef : 'FLW_' . $txId, $paymentType, 'successful', '', $txId);
    }
    pm_exec(
        "UPDATE payment_events SET status = 'processed', amount = ?, fee = ?, u_uid = ?, processed_at = UTC_TIMESTAMP(), updated_at = UTC_TIMESTAMP() WHERE id = ?",
        'ddsi',
        [$amount, $appFee, $userUid, (int)$ev['id']]
    );
    return 'processed';
});

if ($outcome === 'orphan') {
    pm_log('warning', 'webhook: tx_ref does not match a user', ['tx' => $txId]);
    pm_json(['status' => 'success', 'message' => 'Recorded (no matching account)', 'data' => null], 200);
}
if ($outcome === 'duplicate') {
    pm_json(['status' => 'success', 'message' => 'Already processed', 'data' => null], 200);
}

$net = $amount - $appFee;
pm_defer(static function () use ($userUid, $amount, $net, $paymentType): void {
    pm_activity($userUid, 'Funded ₦' . number_format($amount, 2) . ' (net ₦' . number_format($net, 2) . ')');
    credit_alert_app($amount, $userUid);
    $contact = pm_user_contact($userUid);
    if ($contact) {
        email_credit_account((string)$contact['email'], (string)$contact['fname'], $paymentType, $amount, (float)(pm_wallet_balance($userUid) ?? 0));
    }
});

pm_json(['status' => 'success', 'message' => 'Transaction processed successfully', 'data' => null], 200);
