<?php
declare(strict_types=1);

/**
 * Firebase Cloud Messaging — HTTP v1 sender (the legacy /fcm/send API is shut down).
 *
 * .env keys:
 *   FCM_SERVICE_ACCOUNT_JSON  absolute path to the Google service-account JSON
 *                             (store it OUTSIDE the web root, chmod 600)
 *   FCM_PROJECT_ID            optional; defaults to project_id inside the JSON
 *   FCM_TOKEN_CACHE_DIR       optional; directory for the cached OAuth2 access token
 *                             (defaults to sys_get_temp_dir()). APCu is used when available.
 *
 * Flow: build a JWT (RS256, signed with openssl using the service-account private key),
 * exchange it at the token_uri for an OAuth2 access token (cached until ~5 min before
 * expiry), then POST to https://fcm.googleapis.com/v1/projects/{id}/messages:send.
 */

if (isset($_SERVER['SCRIPT_FILENAME']) && realpath((string)$_SERVER['SCRIPT_FILENAME']) === __FILE__) {
    http_response_code(404);
    exit;
}

require_once __DIR__ . '/unique_1.php';

const PM_FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';

function pm_fcm_b64url(string $bin): string
{
    return rtrim(strtr(base64_encode($bin), '+/', '-_'), '=');
}

/** @return array|null decoded service account, or null when not configured */
function pm_fcm_service_account(): ?array
{
    static $sa = false;
    if ($sa !== false) {
        return $sa;
    }
    $sa = null;
    $path = env_data('FCM_SERVICE_ACCOUNT_JSON');
    if ($path === '' || !is_readable($path)) {
        error_log('[pickme] FCM disabled: FCM_SERVICE_ACCOUNT_JSON missing or unreadable');
        return null;
    }
    $json = json_decode((string)file_get_contents($path), true);
    if (!is_array($json) || empty($json['client_email']) || empty($json['private_key'])) {
        error_log('[pickme] FCM disabled: service account JSON invalid');
        return null;
    }
    $sa = $json;
    return $sa;
}

function pm_fcm_cache_file(string $clientEmail): string
{
    $dir = env_data('FCM_TOKEN_CACHE_DIR');
    if ($dir === '') {
        $dir = sys_get_temp_dir();
    }
    return rtrim($dir, '/') . '/pickme_fcm_' . hash('sha256', $clientEmail) . '.json';
}

function pm_fcm_cache_get(string $key, string $file): ?string
{
    if (function_exists('apcu_fetch') && filter_var(ini_get('apc.enabled'), FILTER_VALIDATE_BOOLEAN)) {
        $ok = false;
        $v = apcu_fetch($key, $ok);
        if ($ok && is_array($v) && ($v['exp'] ?? 0) > time() + 300) {
            return (string)$v['token'];
        }
    }
    if (is_readable($file)) {
        $v = json_decode((string)@file_get_contents($file), true);
        if (is_array($v) && ($v['exp'] ?? 0) > time() + 300 && !empty($v['token'])) {
            return (string)$v['token'];
        }
    }
    return null;
}

function pm_fcm_cache_put(string $key, string $file, string $token, int $exp): void
{
    $payload = ['token' => $token, 'exp' => $exp];
    if (function_exists('apcu_store') && filter_var(ini_get('apc.enabled'), FILTER_VALIDATE_BOOLEAN)) {
        apcu_store($key, $payload, max(60, $exp - time()));
    }
    $tmp = $file . '.' . bin2hex(random_bytes(4)) . '.tmp';
    if (@file_put_contents($tmp, json_encode($payload), LOCK_EX) !== false) {
        @chmod($tmp, 0600);
        @rename($tmp, $file);
    }
}

function pm_fcm_http(string $url, array $headers, string $body, int $timeout = 6): array
{
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => $body,
        CURLOPT_HTTPHEADER     => $headers,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT => 3,
        CURLOPT_TIMEOUT        => $timeout,
        CURLOPT_SSL_VERIFYPEER => true,
        CURLOPT_SSL_VERIFYHOST => 2,
    ]);
    $resp = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err  = curl_error($ch);
    curl_close($ch);
    return [$code, is_string($resp) ? $resp : '', $err];
}

/** Returns a cached or fresh OAuth2 access token, or null on failure. */
function pm_fcm_access_token(bool $forceRefresh = false): ?string
{
    $sa = pm_fcm_service_account();
    if ($sa === null) {
        return null;
    }
    $cacheKey = 'pickme_fcm_token_' . hash('sha256', (string)$sa['client_email']);
    $file = pm_fcm_cache_file((string)$sa['client_email']);

    if (!$forceRefresh) {
        $cached = pm_fcm_cache_get($cacheKey, $file);
        if ($cached !== null) {
            return $cached;
        }
    }

    $tokenUri = (string)($sa['token_uri'] ?? 'https://oauth2.googleapis.com/token');
    $now = time();
    $header = pm_fcm_b64url((string)json_encode(['alg' => 'RS256', 'typ' => 'JWT']));
    $claims = pm_fcm_b64url((string)json_encode([
        'iss'   => $sa['client_email'],
        'scope' => PM_FCM_SCOPE,
        'aud'   => $tokenUri,
        'iat'   => $now,
        'exp'   => $now + 3600,
    ]));
    $signingInput = $header . '.' . $claims;
    $key = openssl_pkey_get_private((string)$sa['private_key']);
    if ($key === false) {
        error_log('[pickme] FCM: cannot load service-account private key');
        return null;
    }
    $signature = '';
    if (!openssl_sign($signingInput, $signature, $key, OPENSSL_ALGO_SHA256)) {
        error_log('[pickme] FCM: JWT signing failed');
        return null;
    }
    $jwt = $signingInput . '.' . pm_fcm_b64url($signature);

    [$code, $body, $err] = pm_fcm_http(
        $tokenUri,
        ['Content-Type: application/x-www-form-urlencoded'],
        http_build_query(['grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer', 'assertion' => $jwt])
    );
    $json = json_decode($body, true);
    if ($code !== 200 || !is_array($json) || empty($json['access_token'])) {
        error_log('[pickme] FCM: token exchange failed http=' . $code . ' ' . $err);
        return null;
    }
    $exp = $now + (int)($json['expires_in'] ?? 3600);
    pm_fcm_cache_put($cacheKey, $file, (string)$json['access_token'], $exp);
    return (string)$json['access_token'];
}

/**
 * Sends one message to one device token.
 *
 * @param array $data string=>string map (non-strings are cast)
 * @return string 'ok' | 'unregistered' | 'error' | 'disabled'
 */
function pm_fcm_send(string $deviceToken, string $title, string $body, array $data = [], bool $dataOnly = false): string
{
    $deviceToken = trim($deviceToken);
    if ($deviceToken === '') {
        return 'error';
    }
    $sa = pm_fcm_service_account();
    if ($sa === null) {
        return 'disabled';
    }
    $projectId = env_data('FCM_PROJECT_ID') ?: (string)($sa['project_id'] ?? '');
    if ($projectId === '') {
        error_log('[pickme] FCM: project id unknown');
        return 'disabled';
    }

    $stringData = [];
    foreach ($data as $k => $v) {
        $stringData[(string)$k] = is_scalar($v) ? (string)$v : (string)json_encode($v);
    }
    $stringData['title'] = $stringData['title'] ?? $title;
    $stringData['body']  = $stringData['body'] ?? $body;

    $message = [
        'token'   => $deviceToken,
        'data'    => (object)$stringData,
        'android' => ['priority' => 'HIGH'],
        'apns'    => ['headers' => ['apns-priority' => '10'], 'payload' => ['aps' => ['sound' => 'default']]],
    ];
    if (!$dataOnly) {
        $message['notification'] = ['title' => $title, 'body' => $body];
    }
    $payload = (string)json_encode(['message' => $message], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    $url = 'https://fcm.googleapis.com/v1/projects/' . rawurlencode($projectId) . '/messages:send';

    for ($attempt = 0; $attempt < 2; $attempt++) {
        $access = pm_fcm_access_token($attempt > 0);
        if ($access === null) {
            return 'error';
        }
        [$code, $resp] = pm_fcm_http($url, ['Content-Type: application/json; charset=utf-8', 'Authorization: Bearer ' . $access], $payload);
        if ($code === 200) {
            return 'ok';
        }
        if ($code === 401 && $attempt === 0) {
            continue; // token revoked/expired early: refresh once
        }
        $err = json_decode($resp, true);
        $status = (string)($err['error']['status'] ?? '');
        $detail = '';
        foreach (($err['error']['details'] ?? []) as $d) {
            if (isset($d['errorCode'])) {
                $detail = (string)$d['errorCode'];
            }
        }
        if ($code === 404 || $detail === 'UNREGISTERED' || ($code === 400 && $detail === 'INVALID_ARGUMENT' && stripos($resp, 'registration token') !== false)) {
            return 'unregistered';
        }
        error_log('[pickme] FCM send failed http=' . $code . ' status=' . $status . ' detail=' . $detail);
        return 'error';
    }
    return 'error';
}

/**
 * Sends to every device registered for a user (app_users) and prunes dead tokens.
 * Returns number of successful deliveries.
 */
function pm_push_to_user(mysqli $db, string $uid, string $title, string $body, array $data = [], bool $dataOnly = false): int
{
    if ($uid === '') {
        return 0;
    }
    $stmt = $db->prepare('SELECT id, u_token FROM app_users WHERE uid = ? ORDER BY date_time DESC LIMIT 5');
    $stmt->bind_param('s', $uid);
    $stmt->execute();
    $res = $stmt->get_result();
    $rows = $res ? $res->fetch_all(MYSQLI_ASSOC) : [];
    $stmt->close();

    $sent = 0;
    foreach ($rows as $row) {
        $result = pm_fcm_send((string)$row['u_token'], $title, $body, $data, $dataOnly);
        if ($result === 'ok') {
            $sent++;
        } elseif ($result === 'unregistered') {
            $del = $db->prepare('DELETE FROM app_users WHERE id = ? LIMIT 1');
            $id = (int)$row['id'];
            $del->bind_param('i', $id);
            $del->execute();
            $del->close();
        } elseif ($result === 'disabled') {
            break;
        }
    }
    return $sent;
}
