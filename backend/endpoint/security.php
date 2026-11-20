<?php
declare(strict_types=1);

/**
 * Pick Me API — central security & request helpers.
 *
 * Implements the server side of docs/SECURITY_CONTRACT.md:
 *   - error envelope  { error:true, code, message }               (§4)
 *   - app-key check   Authorization: <APP_KEY sha256 hex>          (§1)
 *   - per-user sessions via X-Session-Token (sha256 stored)        (§2)
 *   - identity derived from the session, uid params asserted       (§3)
 *   - DB-backed rate limiting                                      (§7)
 *   - password hashing with transparent legacy sha256 upgrade      (§7)
 *
 * Every endpoint starts with:   require_once __DIR__ . '/security.php';
 * then either pm_require_app_key() (public endpoints) or $uid = pm_require_session().
 */

if (isset($_SERVER['SCRIPT_FILENAME']) && realpath((string)$_SERVER['SCRIPT_FILENAME']) === __FILE__) {
    http_response_code(404);
    exit;
}

if (defined('PM_SECURITY_LOADED')) {
    return;
}
define('PM_SECURITY_LOADED', true);

const PM_SESSION_TTL_SEC        = 30 * 86400; // sliding 30 days
const PM_SESSION_TOUCH_SEC      = 300;        // refresh last_seen/expiry at most every 5 min
const PM_SESSION_MAX_PER_USER   = 10;
const PM_LEGACY_APP_KEY_PLAIN   = 'byco101###!'; // only used when APP_KEY_SHA256 is not configured

/** Ride statuses in which a driver is busy (legacy aliases included). */
const PM_RIDE_ACTIVE_STATUSES = ['accepted', 'enroute_pickup', 'arrived_pickup', 'in_progress', 'arrived_destination', 'driver_assigned', 'in_ride'];
/** Non-terminal ride statuses. */
const PM_RIDE_OPEN_STATUSES = ['searching', 'accepted', 'enroute_pickup', 'arrived_pickup', 'in_progress', 'arrived_destination', 'driver_assigned', 'in_ride'];

// ---------------------------------------------------------------------------
// Runtime hardening
// ---------------------------------------------------------------------------
ini_set('display_errors', '0');
ini_set('display_startup_errors', '0');
ini_set('log_errors', '1');
error_reporting(E_ALL);
date_default_timezone_set('Africa/Lagos'); // legacy rows store Nigeria local time (GMT+1)

if (!headers_sent()) {
    header_remove('X-Powered-By');
    header('Content-Type: application/json; charset=utf-8');
    header('X-Content-Type-Options: nosniff');
    header('Cache-Control: no-store, max-age=0');
    header('Pragma: no-cache');
    header('Referrer-Policy: no-referrer');
    header('X-Frame-Options: DENY');
}

// CORS is intentionally OFF (native mobile client only): no Access-Control-* headers are sent.
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'OPTIONS') {
    http_response_code(204);
    exit;
}

require_once __DIR__ . '/../unique/unique_con.php'; // $dbconn (mysqli, strict error reporting)

final class PmHttpError extends RuntimeException
{
    public string $apiCode;
    public int $httpStatus;
    public array $extra;

    public function __construct(string $apiCode, string $message, int $httpStatus = 0, array $extra = [])
    {
        parent::__construct($message);
        $this->apiCode = $apiCode;
        $this->httpStatus = $httpStatus > 0 ? $httpStatus : pm_default_status($apiCode);
        $this->extra = $extra;
    }
}

function pm_default_status(string $code): int
{
    switch ($code) {
        case 'UNAUTHORIZED':
        case 'SESSION_EXPIRED':
            return 401;
        case 'FORBIDDEN':
            return 403;
        case 'NOT_FOUND':
            return 404;
        case 'CONFLICT':
            return 409;
        case 'VALIDATION':
            return 422;
        case 'RATE_LIMITED':
            return 429;
        default:
            return 500;
    }
}

// ---------------------------------------------------------------------------
// Logging / output
// ---------------------------------------------------------------------------
function pm_log(string $level, string $message, array $context = []): void
{
    $line = ['ts' => gmdate('c'), 'level' => $level, 'msg' => $message, 'script' => basename((string)($_SERVER['SCRIPT_NAME'] ?? 'cli'))];
    if ($context) {
        $line['ctx'] = $context;
    }
    error_log('[pickme] ' . json_encode($line, JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE));
}

/** Sends a JSON payload and terminates. */
function pm_json(array $payload, int $status = 200): void
{
    if (isset($GLOBALS['PM_IDEM']) && $status < 300 && empty($payload['error'])) {
        pm_idempotency_store($payload, $status);
    }
    if (!headers_sent()) {
        http_response_code($status);
        if (isset($GLOBALS['PM_SESSION']['expires_iso'])) {
            header('X-Session-Expires-At: ' . $GLOBALS['PM_SESSION']['expires_iso']);
        }
    }
    $out = json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
    echo $out === false ? '{"error":true,"code":"SERVER","message":"Encoding error"}' : $out;
    exit;
}

/**
 * Error envelope (contract §4). $extra keys are merged in for backward compatibility
 * (e.g. legacy 'login_msg', 'data' => null, 'drivers' => []).
 */
function pm_error(string $code, string $message, int $status = 0, array $extra = []): void
{
    $status = $status > 0 ? $status : pm_default_status($code);
    if ($code === 'RATE_LIMITED' && isset($extra['retry_after']) && !headers_sent()) {
        header('Retry-After: ' . (int)$extra['retry_after']);
    }
    pm_json(array_merge(['error' => true, 'code' => $code, 'message' => $message], $extra), $status);
}

function pm_fail(string $code, string $message, int $status = 0, array $extra = []): void
{
    throw new PmHttpError($code, $message, $status, $extra);
}

set_exception_handler(static function (Throwable $e): void {
    if ($e instanceof PmHttpError) {
        pm_error($e->apiCode, $e->getMessage(), $e->httpStatus, $e->extra);
    }
    pm_log('error', 'unhandled exception', [
        'type' => get_class($e),
        'msg'  => $e->getMessage(),
        'at'   => basename($e->getFile()) . ':' . $e->getLine(),
    ]);
    pm_error('SERVER', 'Something went wrong. Please try again.', 500);
});

// ---------------------------------------------------------------------------
// Deferred work (push / e-mail after the response has been flushed)
// ---------------------------------------------------------------------------
function pm_defer(callable $fn): void
{
    static $registered = false;
    $GLOBALS['PM_DEFERRED'][] = $fn;
    if ($registered) {
        return;
    }
    $registered = true;
    register_shutdown_function(static function (): void {
        if (function_exists('fastcgi_finish_request')) {
            @fastcgi_finish_request();
        } elseif (function_exists('litespeed_finish_request')) {
            @litespeed_finish_request();
        }
        ignore_user_abort(true);
        foreach ($GLOBALS['PM_DEFERRED'] ?? [] as $job) {
            try {
                $job();
            } catch (Throwable $t) {
                pm_log('warning', 'deferred job failed', ['type' => get_class($t), 'msg' => $t->getMessage()]);
            }
        }
    });
}

// ---------------------------------------------------------------------------
// Env / DB helpers
// ---------------------------------------------------------------------------
function pm_env(string $key, string $default = ''): string
{
    $v = env_data($key);
    return $v !== '' ? $v : $default;
}

function pm_db(): mysqli
{
    global $dbconn;
    return $dbconn;
}

/** Legacy mysqli_query() returned every column as string; keep that for response compatibility. */
function pm_row_str(array $row): array
{
    foreach ($row as $k => $v) {
        if (is_int($v) || is_float($v)) {
            $row[$k] = (string)$v;
        }
    }
    return $row;
}

function pm_stmt(string $sql, string $types = '', array $params = []): mysqli_stmt
{
    $stmt = pm_db()->prepare($sql);
    if ($types !== '') {
        $values = array_values($params);
        $stmt->bind_param($types, ...$values);
    }
    $stmt->execute();
    return $stmt;
}

function pm_q_all(string $sql, string $types = '', array $params = []): array
{
    $stmt = pm_stmt($sql, $types, $params);
    $res = $stmt->get_result();
    $rows = [];
    if ($res) {
        while ($r = $res->fetch_assoc()) {
            $rows[] = pm_row_str($r);
        }
        $res->free();
    }
    $stmt->close();
    return $rows;
}

function pm_q_one(string $sql, string $types = '', array $params = []): ?array
{
    $rows = pm_q_all($sql, $types, $params);
    return $rows[0] ?? null;
}

/** Executes a write; returns affected rows. */
function pm_exec(string $sql, string $types = '', array $params = []): int
{
    $stmt = pm_stmt($sql, $types, $params);
    $n = (int)$stmt->affected_rows;
    $stmt->close();
    return $n;
}

/** Executes an INSERT; returns the new auto-increment id. */
function pm_insert(string $sql, string $types = '', array $params = []): int
{
    $stmt = pm_stmt($sql, $types, $params);
    $id = (int)$stmt->insert_id;
    $stmt->close();
    return $id;
}

/** IN (?,?,?) placeholder list for a fixed, server-defined array of strings. */
function pm_in_placeholders(array $values): string
{
    return implode(',', array_fill(0, max(1, count($values)), '?'));
}

/**
 * Runs $fn inside a transaction; retries on deadlock / lock-wait timeout.
 * Nested calls join the outer transaction.
 */
function pm_tx(callable $fn)
{
    static $depth = 0;
    if ($depth > 0) {
        return $fn();
    }
    $db = pm_db();
    for ($attempt = 1; ; $attempt++) {
        $depth++;
        $db->begin_transaction();
        try {
            $result = $fn();
            $db->commit();
            $depth--;
            return $result;
        } catch (Throwable $e) {
            try {
                $db->rollback();
            } catch (Throwable $ignored) {
            }
            $depth--;
            $retryable = $e instanceof mysqli_sql_exception && in_array((int)$e->getCode(), [1205, 1213], true);
            if ($retryable && $attempt < 3) {
                usleep(random_int(20000, 80000) * $attempt);
                continue;
            }
            throw $e;
        }
    }
}

// ---------------------------------------------------------------------------
// Request helpers
// ---------------------------------------------------------------------------
function pm_header(string $name): string
{
    $key = 'HTTP_' . strtoupper(str_replace('-', '_', $name));
    if (isset($_SERVER[$key]) && is_string($_SERVER[$key])) {
        return trim($_SERVER[$key]);
    }
    if ($key === 'HTTP_AUTHORIZATION') {
        foreach (['REDIRECT_HTTP_AUTHORIZATION', 'Authorization'] as $alt) {
            if (isset($_SERVER[$alt]) && is_string($_SERVER[$alt])) {
                return trim($_SERVER[$alt]);
            }
        }
    }
    static $all = null;
    if ($all === null) {
        $all = [];
        if (function_exists('getallheaders')) {
            foreach ((array)getallheaders() as $k => $v) {
                $all[strtolower((string)$k)] = (string)$v;
            }
        }
    }
    return trim($all[strtolower($name)] ?? '');
}

function pm_require_method(string ...$methods): void
{
    $m = strtoupper((string)($_SERVER['REQUEST_METHOD'] ?? 'GET'));
    if (!in_array($m, $methods, true)) {
        if (!headers_sent()) {
            header('Allow: ' . implode(', ', $methods));
        }
        pm_error('VALIDATION', 'Method not allowed.', 405);
    }
}

/** Request params: JSON body (if any) merged over form/multipart POST fields. */
function pm_input(): array
{
    static $in = null;
    if ($in !== null) {
        return $in;
    }
    $in = is_array($_POST) ? $_POST : [];
    $ctype = strtolower((string)($_SERVER['CONTENT_TYPE'] ?? ''));
    if (strpos($ctype, 'multipart/form-data') === false) {
        $raw = file_get_contents('php://input', false, null, 0, 1048576);
        if (is_string($raw) && $raw !== '' && ($raw[0] === '{' || strpos($ctype, 'json') !== false)) {
            $json = json_decode($raw, true);
            if (is_array($json)) {
                $in = array_merge($in, $json);
            }
        }
    }
    return $in;
}

/**
 * Client idempotency key: `Idempotency-Key` / `X-Idempotency-Key` header, or the
 * `idempotency_key` / `client_request_id` / `request_id` param. '' when absent or malformed.
 */
function pm_idempotency_key(): string
{
    $k = pm_header('Idempotency-Key');
    if ($k === '') {
        $k = pm_header('X-Idempotency-Key');
    }
    if ($k === '') {
        $in = pm_input();
        foreach (['idempotency_key', 'client_request_id', 'request_id'] as $p) {
            if (isset($in[$p]) && is_scalar($in[$p]) && trim((string)$in[$p]) !== '') {
                $k = trim((string)$in[$p]);
                break;
            }
        }
    }
    return preg_match('/^[A-Za-z0-9_\-:.]{8,64}$/', $k) ? $k : '';
}

/**
 * Replays the stored response if ($uid, $scope, key) was already completed successfully (24 h window);
 * otherwise arms pm_json() to store this request's successful response.
 */
function pm_idempotency_begin(string $uid, string $scope): void
{
    $key = pm_idempotency_key();
    if ($key === '' || $uid === '') {
        return;
    }
    try {
        $row = pm_q_one(
            'SELECT http_status, response FROM idempotency_keys
             WHERE u_uid = ? AND scope = ? AND idem_key = ? AND created_at > DATE_SUB(UTC_TIMESTAMP(), INTERVAL 1 DAY) LIMIT 1',
            'sss',
            [$uid, $scope, $key]
        );
    } catch (mysqli_sql_exception $e) {
        pm_log('warning', 'idempotency store unavailable', ['msg' => $e->getMessage()]);
        return;
    }
    if ($row !== null) {
        $payload = json_decode((string)$row['response'], true);
        if (is_array($payload)) {
            if (!headers_sent()) {
                header('Idempotent-Replay: true');
            }
            $payload['idempotent_replay'] = true;
            pm_json($payload, (int)$row['http_status']);
        }
    }
    $GLOBALS['PM_IDEM'] = ['uid' => $uid, 'scope' => $scope, 'key' => $key];
}

function pm_idempotency_store(array $payload, int $status): void
{
    $idem = $GLOBALS['PM_IDEM'];
    unset($GLOBALS['PM_IDEM']);
    try {
        pm_exec(
            'INSERT IGNORE INTO idempotency_keys (u_uid, scope, idem_key, http_status, response, created_at) VALUES (?, ?, ?, ?, ?, UTC_TIMESTAMP())',
            'sssis',
            [$idem['uid'], $idem['scope'], $idem['key'], $status, (string)json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE)]
        );
        if (random_int(1, 200) === 1) {
            pm_exec('DELETE FROM idempotency_keys WHERE created_at < DATE_SUB(UTC_TIMESTAMP(), INTERVAL 2 DAY) LIMIT 1000');
        }
    } catch (Throwable $e) {
        pm_log('warning', 'idempotency store failed', ['msg' => $e->getMessage()]);
    }
}

function pm_client_ip(): string
{
    $remote = (string)($_SERVER['REMOTE_ADDR'] ?? '0.0.0.0');
    $trusted = array_filter(array_map('trim', explode(',', pm_env('TRUSTED_PROXY_IPS'))));
    if ($trusted && in_array($remote, $trusted, true)) {
        $xff = (string)($_SERVER['HTTP_X_FORWARDED_FOR'] ?? '');
        $first = trim(explode(',', $xff)[0] ?? '');
        if ($first !== '' && filter_var($first, FILTER_VALIDATE_IP)) {
            return $first;
        }
    }
    return $remote;
}

// ---------------------------------------------------------------------------
// Input validation
// ---------------------------------------------------------------------------
function pm_clean_text($v, int $maxLen = 255): string
{
    if ($v === null || is_array($v) || is_object($v)) {
        return '';
    }
    $s = (string)$v;
    if (!mb_check_encoding($s, 'UTF-8')) {
        $s = mb_convert_encoding($s, 'UTF-8', 'UTF-8');
    }
    $s = preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u', '', $s) ?? '';
    $s = trim(strip_tags($s));
    if (mb_strlen($s) > $maxLen) {
        $s = mb_substr($s, 0, $maxLen);
    }
    return $s;
}

/** First non-empty value among $keys, cleaned. */
function pm_in_str(array $in, $keys, int $maxLen = 255, string $default = ''): string
{
    foreach ((array)$keys as $k) {
        if (array_key_exists($k, $in)) {
            $v = pm_clean_text($in[$k], $maxLen);
            if ($v !== '' && strtolower($v) !== 'null') {
                return $v;
            }
        }
    }
    return $default;
}

/** Raw (untrimmed, untouched) string such as a password; arrays rejected. */
function pm_in_raw(array $in, string $key, int $maxLen = 1024): string
{
    $v = $in[$key] ?? '';
    if (!is_scalar($v)) {
        return '';
    }
    $s = (string)$v;
    return strlen($s) > $maxLen ? substr($s, 0, $maxLen) : $s;
}

function pm_in_int(array $in, $keys, int $default = 0, ?int $min = null, ?int $max = null): int
{
    foreach ((array)$keys as $k) {
        if (isset($in[$k]) && is_scalar($in[$k]) && is_numeric(trim((string)$in[$k]))) {
            $v = (int)trim((string)$in[$k]);
            if ($min !== null && $v < $min) {
                $v = $min;
            }
            if ($max !== null && $v > $max) {
                $v = $max;
            }
            return $v;
        }
    }
    return $default;
}

function pm_in_float(array $in, $keys, float $default = 0.0): float
{
    foreach ((array)$keys as $k) {
        if (isset($in[$k]) && is_scalar($in[$k]) && is_numeric(trim((string)$in[$k]))) {
            $v = (float)trim((string)$in[$k]);
            return is_finite($v) ? $v : $default;
        }
    }
    return $default;
}

function pm_valid_lat(float $lat): bool
{
    return is_finite($lat) && $lat >= -90.0 && $lat <= 90.0 && $lat != 0.0;
}

function pm_valid_lng(float $lng): bool
{
    return is_finite($lng) && $lng >= -180.0 && $lng <= 180.0 && $lng != 0.0;
}

function pm_in_enum(array $in, $keys, array $allowed, string $default): string
{
    $v = strtolower(pm_in_str($in, $keys, 64));
    return in_array($v, $allowed, true) ? $v : $default;
}

function pm_normalize_phone(string $phone): string
{
    $p = preg_replace('/[\s\-().]/', '', $phone) ?? '';
    return preg_match('/^\+?[0-9]{7,15}$/', $p) ? $p : '';
}

function pm_random_digits(int $n): string
{
    $out = '';
    for ($i = 0; $i < $n; $i++) {
        $out .= (string)random_int(0, 9);
    }
    return $out;
}

function pm_random_string(int $len, string $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789'): string
{
    $max = strlen($alphabet) - 1;
    $out = '';
    for ($i = 0; $i < $len; $i++) {
        $out .= $alphabet[random_int(0, $max)];
    }
    return $out;
}

/** Local (Africa/Lagos) timestamp parts for legacy datetime/date/time columns. */
function pm_legacy_now(): array
{
    return [
        'datetime' => date('Y-m-d H:i:s'),
        'date'     => date('l, jS F Y'),
        'time'     => date('g:iA'),
    ];
}

// ---------------------------------------------------------------------------
// App key (contract §1) — identifies the app build, never the user
// ---------------------------------------------------------------------------
function pm_app_key_valid(string $presented): bool
{
    $presented = strtolower(trim($presented));
    if ($presented === '') {
        return false;
    }
    $configured = array_filter(array_map(static fn($k) => strtolower(trim($k)), explode(',', pm_env('APP_KEY_SHA256'))));
    if (!$configured) {
        static $warned = false;
        if (!$warned) {
            pm_log('warning', 'APP_KEY_SHA256 not configured; falling back to legacy app key');
            $warned = true;
        }
        $configured = [hash('sha256', PM_LEGACY_APP_KEY_PLAIN)];
    }
    $ok = false;
    foreach ($configured as $k) {
        $ok = hash_equals($k, $presented) || $ok; // no early exit
    }
    return $ok;
}

function pm_require_app_key(array $extra = []): void
{
    if (!pm_app_key_valid(pm_header('Authorization'))) {
        pm_error('UNAUTHORIZED', 'Unauthorized access', 401, $extra + ['data' => null]);
    }
}

// ---------------------------------------------------------------------------
// Rate limiting (fixed window, table rate_limits)
// ---------------------------------------------------------------------------
function pm_rate_limit(string $bucket, string $key, int $max, int $windowSec, string $message = 'Too many attempts. Please wait and try again.'): void
{
    $now = time();
    $windowStart = intdiv($now, $windowSec) * $windowSec;
    $expiresAt = $windowStart + $windowSec;
    $keyHash = hash('sha256', $bucket . '|' . $key);
    try {
        $db = pm_db();
        $stmt = $db->prepare(
            'INSERT INTO rate_limits (bucket, key_hash, window_start, hits, expires_at) VALUES (?, ?, ?, 1, ?)
             ON DUPLICATE KEY UPDATE hits = LAST_INSERT_ID(hits + 1)'
        );
        $stmt->bind_param('ssii', $bucket, $keyHash, $windowStart, $expiresAt);
        $stmt->execute();
        $affected = (int)$stmt->affected_rows;
        $hits = $affected === 1 ? 1 : (int)$stmt->insert_id;
        $stmt->close();
        if ($hits <= 0) {
            $row = pm_q_one('SELECT hits FROM rate_limits WHERE bucket = ? AND key_hash = ? AND window_start = ?', 'ssi', [$bucket, $keyHash, $windowStart]);
            $hits = (int)($row['hits'] ?? 1);
        }
        if (random_int(1, 200) === 1) {
            pm_exec('DELETE FROM rate_limits WHERE expires_at < ? LIMIT 1000', 'i', [$now]);
        }
    } catch (mysqli_sql_exception $e) {
        pm_log('error', 'rate limiter unavailable (fail-open)', ['msg' => $e->getMessage()]);
        return;
    }
    if ($hits > $max) {
        pm_error('RATE_LIMITED', $message, 429, ['retry_after' => max(1, $expiresAt - $now), 'data' => null]);
    }
}

function pm_rate_limit_clear(string $bucket, string $key): void
{
    try {
        pm_exec('DELETE FROM rate_limits WHERE bucket = ? AND key_hash = ?', 'ss', [$bucket, hash('sha256', $bucket . '|' . $key)]);
    } catch (mysqli_sql_exception $e) {
        pm_log('warning', 'rate limit clear failed', ['msg' => $e->getMessage()]);
    }
}

// ---------------------------------------------------------------------------
// Passwords / PINs (contract §7)
// ---------------------------------------------------------------------------
function pm_password_algo()
{
    return defined('PASSWORD_ARGON2ID') ? PASSWORD_ARGON2ID : PASSWORD_BCRYPT;
}

function pm_password_options(): array
{
    return defined('PASSWORD_ARGON2ID')
        ? ['memory_cost' => 19456, 'time_cost' => 2, 'threads' => 1] // OWASP baseline, bounded RAM per login
        : ['cost' => 12];
}

function pm_password_hash(string $secret): string
{
    return password_hash($secret, pm_password_algo(), pm_password_options());
}

/**
 * @return array{0: bool, 1: bool} [matches, needsRehash]
 * Supports legacy unsalted sha256 hex (upgraded on success) and password_hash() formats.
 */
function pm_password_check(string $secret, string $stored): array
{
    $stored = trim($stored);
    if ($stored === '') {
        static $dummy = null;
        if ($dummy === null) {
            $dummy = pm_password_hash(bin2hex(random_bytes(8)));
        }
        password_verify($secret, $dummy); // equalise timing for unknown accounts
        return [false, false];
    }
    if (preg_match('/^[a-f0-9]{64}$/i', $stored)) {
        $ok = hash_equals(strtolower($stored), hash('sha256', $secret));
        return [$ok, $ok];
    }
    $info = password_get_info($stored);
    if (($info['algo'] ?? null) === null || ($info['algo'] ?? 0) === 0) {
        return [false, false];
    }
    $ok = password_verify($secret, $stored);
    return [$ok, $ok && password_needs_rehash($stored, pm_password_algo(), pm_password_options())];
}

function pm_valid_pin(string $pin): bool
{
    return (bool)preg_match('/^[0-9]{4,6}$/', $pin);
}

// ---------------------------------------------------------------------------
// Sessions (contract §2)
// ---------------------------------------------------------------------------
function pm_iso_utc(int $ts): string
{
    return gmdate('Y-m-d\TH:i:s\Z', $ts);
}

/** Issues a new session for $uid. Returns ['session_token' => ..., 'session_expires_at' => ISO-8601 UTC]. */
function pm_session_issue(string $uid): array
{
    $token = bin2hex(random_bytes(32));
    $hash = hash('sha256', $token);
    $expires = time() + PM_SESSION_TTL_SEC;
    $ip = pm_client_ip();
    $ua = mb_substr((string)($_SERVER['HTTP_USER_AGENT'] ?? ''), 0, 255);
    $platform = mb_substr(strtolower(pm_header('X-Client-Platform')), 0, 16);
    $version = mb_substr(pm_header('X-Client-Version'), 0, 32);

    pm_exec(
        'INSERT INTO user_sessions (u_uid, token_hash, created_at, last_seen_at, expires_at, ip, user_agent, platform, app_version)
         VALUES (?, ?, UTC_TIMESTAMP(), UTC_TIMESTAMP(), DATE_ADD(UTC_TIMESTAMP(), INTERVAL ? SECOND), ?, ?, ?, ?)',
        'ssissss',
        [$uid, $hash, PM_SESSION_TTL_SEC, $ip, $ua, $platform, $version]
    );

    // Cap concurrent sessions per user (oldest revoked first).
    $active = pm_q_all(
        'SELECT id FROM user_sessions WHERE u_uid = ? AND revoked_at IS NULL AND expires_at > UTC_TIMESTAMP() ORDER BY last_seen_at DESC',
        's',
        [$uid]
    );
    if (count($active) > PM_SESSION_MAX_PER_USER) {
        foreach (array_slice($active, PM_SESSION_MAX_PER_USER) as $old) {
            pm_exec('UPDATE user_sessions SET revoked_at = UTC_TIMESTAMP(), revoke_reason = ? WHERE id = ?', 'si', ['session_cap', (int)$old['id']]);
        }
    }
    if (random_int(1, 100) === 1) {
        pm_exec('DELETE FROM user_sessions WHERE expires_at < DATE_SUB(UTC_TIMESTAMP(), INTERVAL 30 DAY) LIMIT 1000');
    }
    return ['session_token' => $token, 'session_expires_at' => pm_iso_utc($expires)];
}

/** Looks up a raw token. Returns the row (with user sta) or null. */
function pm_session_lookup(string $token): ?array
{
    if (!preg_match('/^[a-f0-9]{64}$/', $token)) {
        return null;
    }
    return pm_q_one(
        'SELECT s.id, s.u_uid, s.revoked_at,
                TIMESTAMPDIFF(SECOND, s.last_seen_at, UTC_TIMESTAMP()) AS idle_sec,
                TIMESTAMPDIFF(SECOND, s.created_at, UTC_TIMESTAMP()) AS age_sec,
                TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), s.expires_at) AS ttl_sec,
                u.sta
         FROM user_sessions s
         LEFT JOIN unique_user_table u ON u.u_uid = s.u_uid
         WHERE s.token_hash = ?
         LIMIT 1',
        's',
        [hash('sha256', $token)]
    );
}

function pm_session_revoke_id(int $sessionId, string $reason): void
{
    pm_exec('UPDATE user_sessions SET revoked_at = UTC_TIMESTAMP(), revoke_reason = ? WHERE id = ? AND revoked_at IS NULL', 'si', [$reason, $sessionId]);
}

/** Revokes all sessions of $uid (optionally keeping one). */
function pm_session_revoke_all(string $uid, string $reason, int $exceptSessionId = 0): int
{
    return pm_exec(
        'UPDATE user_sessions SET revoked_at = UTC_TIMESTAMP(), revoke_reason = ? WHERE u_uid = ? AND revoked_at IS NULL AND id <> ?',
        'ssi',
        [$reason, $uid, $exceptSessionId]
    );
}

function pm_current_session(): ?array
{
    return $GLOBALS['PM_SESSION'] ?? null;
}

/**
 * Asserts that identity params sent by the client (uid/user_id/rider_id/user) match the session user.
 * Contract §3: a mismatch is a 403 FORBIDDEN.
 */
function pm_assert_uid_params(string $uid, array $keys = ['uid', 'user_id', 'rider_id', 'user']): void
{
    $in = pm_input();
    foreach ($keys as $k) {
        if (!isset($in[$k]) || !is_scalar($in[$k])) {
            continue;
        }
        $v = trim((string)$in[$k]);
        if ($v === '' || strtolower($v) === 'null') {
            continue;
        }
        if (!hash_equals($uid, $v)) {
            pm_log('warning', 'uid param mismatch', ['param' => $k]);
            pm_error('FORBIDDEN', 'You are not allowed to act on behalf of another account.', 403, ['data' => null]);
        }
    }
}

/**
 * App key + valid session. Returns the session user's u_uid.
 * 401 UNAUTHORIZED (no/unknown token) | 401 SESSION_EXPIRED (expired/revoked) | 403 FORBIDDEN (suspended).
 */
function pm_require_session(array $extra = []): string
{
    pm_require_app_key($extra);
    $token = strtolower(pm_header('X-Session-Token'));
    if ($token === '') {
        pm_error('UNAUTHORIZED', 'Please sign in to continue.', 401, $extra + ['data' => null]);
    }
    $s = pm_session_lookup($token);
    if ($s === null) {
        pm_error('UNAUTHORIZED', 'Please sign in to continue.', 401, $extra + ['data' => null]);
    }
    if ($s['revoked_at'] !== null || (int)$s['ttl_sec'] <= 0 || $s['sta'] === null) {
        pm_error('SESSION_EXPIRED', 'Your session has expired. Please sign in again.', 401, $extra + ['data' => null]);
    }
    $sta = (int)$s['sta'];
    if ($sta === 1) {
        pm_error('FORBIDDEN', 'Your account has been suspended. Please contact support.', 403, $extra + ['data' => null]);
    }
    if ($sta !== 0) {
        pm_session_revoke_id((int)$s['id'], 'account_inactive');
        pm_error('SESSION_EXPIRED', 'Your session has expired. Please sign in again.', 401, $extra + ['data' => null]);
    }

    $ttl = (int)$s['ttl_sec'];
    if ((int)$s['idle_sec'] >= PM_SESSION_TOUCH_SEC) {
        pm_exec(
            'UPDATE user_sessions SET last_seen_at = UTC_TIMESTAMP(), expires_at = DATE_ADD(UTC_TIMESTAMP(), INTERVAL ? SECOND) WHERE id = ?',
            'ii',
            [PM_SESSION_TTL_SEC, (int)$s['id']]
        );
        $ttl = PM_SESSION_TTL_SEC;
    }
    $GLOBALS['PM_SESSION'] = [
        'id'          => (int)$s['id'],
        'uid'         => (string)$s['u_uid'],
        'age_sec'     => (int)$s['age_sec'],
        'expires_iso' => pm_iso_utc(time() + $ttl),
    ];
    pm_assert_uid_params((string)$s['u_uid']);
    return (string)$s['u_uid'];
}

/** Optional session: returns uid when a valid session token is presented, else ''. Never errors. */
function pm_optional_session_uid(): string
{
    $token = strtolower(pm_header('X-Session-Token'));
    if ($token === '') {
        return '';
    }
    $s = pm_session_lookup($token);
    if ($s === null || $s['revoked_at'] !== null || (int)$s['ttl_sec'] <= 0 || (int)($s['sta'] ?? -1) !== 0) {
        return '';
    }
    $GLOBALS['PM_SESSION'] = ['id' => (int)$s['id'], 'uid' => (string)$s['u_uid'], 'age_sec' => (int)$s['age_sec']];
    return (string)$s['u_uid'];
}

// ---------------------------------------------------------------------------
// Ownership helpers
// ---------------------------------------------------------------------------
function pm_normalize_driver_status(string $status): string
{
    $s = strtolower(trim($status));
    if ($s === 'approved' || $s === 'activated') {
        return 'activated';
    }
    if ($s === 'pending' || $s === 'rejected') {
        return $s;
    }
    return 'not_started';
}

/** Latest onboarding row (joined with ride_drivers) for a user, or null. */
function pm_driver_for_user(string $uid): ?array
{
    return pm_q_one(
        'SELECT o.id AS onboarding_id, o.status AS onboarding_status, o.driver_id AS onboarding_driver_id, o.admin_note,
                d.id, d.name, d.phone, d.nin, d.`rank`, d.category, d.rating, d.car_plate, d.vehicle_type, d.seats,
                d.avatar_url, d.completed_trips, d.total_trips, d.cancelled_trips, d.incomplete_trips, d.is_online,
                d.currency, d.allowed_ride_types, d.max_payload_weight, d.current_payload_weight
         FROM ride_driver_onboarding o
         LEFT JOIN ride_drivers d ON d.id = o.driver_id
         WHERE o.user_uid = ?
         ORDER BY o.id DESC
         LIMIT 1',
        's',
        [$uid]
    );
}

/**
 * Resolves the activated driver for the session user. Client-sent driver_id must match (contract §3).
 * $notDriverStatus lets legacy endpoints keep returning HTTP 200 + error:true for "not a driver yet".
 */
function pm_require_driver(string $uid, int $notDriverStatus = 403): array
{
    $row = pm_driver_for_user($uid);
    if ($row === null) {
        pm_fail('FORBIDDEN', 'No driver onboarding record was found for this account.', $notDriverStatus);
    }
    if (pm_normalize_driver_status((string)$row['onboarding_status']) !== 'activated' || $row['id'] === null) {
        pm_fail('FORBIDDEN', 'Driver account is not yet activated.', $notDriverStatus);
    }
    $in = pm_input();
    if (isset($in['driver_id']) && is_scalar($in['driver_id'])) {
        $sent = trim((string)$in['driver_id']);
        if ($sent !== '' && $sent !== '0' && strtolower($sent) !== 'null' && (string)(int)$sent !== (string)(int)$row['id']) {
            pm_log('warning', 'driver_id param mismatch');
            pm_error('FORBIDDEN', 'You are not allowed to act on behalf of another driver.', 403, ['data' => null]);
        }
    }
    return $row;
}

/** Bounding box (degrees) around a point for a radius in km. */
function pm_bbox(float $lat, float $lng, float $radiusKm): array
{
    $latDelta = $radiusKm / 111.045;
    $lngDelta = $radiusKm / (111.045 * max(abs(cos(deg2rad($lat))), 0.000001));
    return [$lat - $latDelta, $lat + $latDelta, $lng - $lngDelta, $lng + $lngDelta];
}

function pm_haversine_m(float $lat1, float $lng1, float $lat2, float $lng2): float
{
    $earth = 6371000.0;
    $dLat = deg2rad($lat2 - $lat1);
    $dLng = deg2rad($lng2 - $lng1);
    $a = sin($dLat / 2) ** 2 + cos(deg2rad($lat1)) * cos(deg2rad($lat2)) * sin($dLng / 2) ** 2;
    return 2.0 * $earth * asin(min(1.0, sqrt($a)));
}

function pm_public_base_url(): string
{
    return rtrim(pm_env('PUBLIC_BASE_URL', 'https://realpickme.com/endpoint'), '/') . '/';
}
