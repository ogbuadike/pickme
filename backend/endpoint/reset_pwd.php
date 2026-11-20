<?php
declare(strict_types=1);

/**
 * reset_pwd.php — PUBLIC password reset (contract §5). No password is ever changed without proof
 * of mailbox ownership.
 *
 * 1) POST (app key) email=<email or phone>
 *      → e-mails a one-time link + 6-digit code (valid 30 min). Response is identical whether or not
 *        the account exists (no enumeration). Rate limited per IP and per identifier.
 * 2a) POST (app key) email, code, new_password          → API completion (for in-app flow)
 * 2b) GET ?token=…  → minimal HTML form; POST token, new_password, confirm_password → web completion
 * Success revokes every session of the user. Codes: 5 wrong attempts invalidate the request.
 */

require_once __DIR__ . '/security.php';
require_once __DIR__ . '/activities.php';

const RESET_TTL_MIN = 30;
const RESET_MAX_ATTEMPTS = 5;

function reset_generic(): void
{
    pm_json(['error' => false, 'message' => 'If an account exists for these details, a password reset link has been sent to its email.']);
}

function reset_html(string $title, string $body, int $status = 200): void
{
    if (!headers_sent()) {
        http_response_code($status);
        header('Content-Type: text/html; charset=utf-8');
        header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");
    }
    $t = htmlspecialchars($title, ENT_QUOTES, 'UTF-8');
    echo '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
        . '<meta name="robots" content="noindex"><title>' . $t . ' - Pick Me</title></head>'
        . '<body style="font-family:Segoe UI,Roboto,Arial,sans-serif;background:#f4f4f4;margin:0;padding:24px;">'
        . '<div style="max-width:420px;margin:40px auto;background:#fff;border-radius:12px;padding:28px;">'
        . '<h1 style="font-size:22px;margin-top:0;">' . $t . '</h1>' . $body . '</div></body></html>';
    exit;
}

function reset_find_by_token(string $token): ?array
{
    if (!preg_match('/^[a-f0-9]{64}$/', $token)) {
        return null;
    }
    return pm_q_one(
        'SELECT id, u_uid, token_hash, attempts FROM password_resets
         WHERE token_hash = ? AND used_at IS NULL AND expires_at > UTC_TIMESTAMP() LIMIT 1',
        's',
        [hash('sha256', $token)]
    );
}

function reset_apply(array $reset, string $newPassword): void
{
    pm_tx(function () use ($reset, $newPassword) {
        $claimed = pm_exec('UPDATE password_resets SET used_at = UTC_TIMESTAMP() WHERE id = ? AND used_at IS NULL', 'i', [(int)$reset['id']]);
        if ($claimed !== 1) {
            pm_fail('CONFLICT', 'This reset link has already been used.', 200);
        }
        pm_exec('UPDATE unique_user_table SET pass_code = ?, reset = 0 WHERE u_uid = ? LIMIT 1', 'ss', [pm_password_hash($newPassword), (string)$reset['u_uid']]);
        pm_exec('UPDATE password_resets SET used_at = UTC_TIMESTAMP() WHERE u_uid = ? AND used_at IS NULL', 's', [(string)$reset['u_uid']]);
        pm_session_revoke_all((string)$reset['u_uid'], 'password_reset');
    });
    pm_activity((string)$reset['u_uid'], 'Password reset completed');
}

$method = strtoupper((string)($_SERVER['REQUEST_METHOD'] ?? 'GET'));
$in = pm_input();
$webToken = strtolower(pm_clean_text($_GET['token'] ?? ($in['token'] ?? ''), 64));

// ---------------------------------------------------------------------------
// Web flow (link from the e-mail) — the token itself is the credential, no app key.
// ---------------------------------------------------------------------------
if ($webToken !== '') {
    pm_rate_limit('reset_web_ip', pm_client_ip(), 30, 900);
    $reset = reset_find_by_token($webToken);
    if ($reset === null) {
        reset_html('Link expired', '<p>This password reset link is invalid or has expired. Please request a new one from the Pick Me app.</p>', 410);
    }
    $form = static function (string $error = '') use ($webToken): string {
        $err = $error !== '' ? '<p style="color:#c00;">' . htmlspecialchars($error, ENT_QUOTES, 'UTF-8') . '</p>' : '';
        return $err . '<form method="post" action="reset_pwd.php" autocomplete="off">'
            . '<input type="hidden" name="token" value="' . htmlspecialchars($webToken, ENT_QUOTES, 'UTF-8') . '">'
            . '<label>New password<br><input type="password" name="new_password" minlength="8" maxlength="128" required style="width:100%;padding:10px;margin:6px 0 14px;"></label>'
            . '<label>Confirm password<br><input type="password" name="confirm_password" minlength="8" maxlength="128" required style="width:100%;padding:10px;margin:6px 0 14px;"></label>'
            . '<button type="submit" style="background:#ffc107;border:0;border-radius:8px;padding:12px 20px;font-weight:bold;">Set new password</button></form>';
    };
    if ($method !== 'POST') {
        reset_html('Choose a new password', $form());
    }
    $new = pm_in_raw($in, 'new_password', 1024);
    $confirm = pm_in_raw($in, 'confirm_password', 1024);
    if (strlen($new) < 8 || strlen($new) > 128) {
        reset_html('Choose a new password', $form('Password must be between 8 and 128 characters.'), 422);
    }
    if (!hash_equals($new, $confirm)) {
        reset_html('Choose a new password', $form('Passwords do not match.'), 422);
    }
    try {
        reset_apply($reset, $new);
    } catch (PmHttpError $e) {
        reset_html('Link expired', '<p>This password reset link has already been used.</p>', 410);
    }
    reset_html('Password updated', '<p>Your password has been changed. You can now sign in to the Pick Me app with your new password.</p>');
}

// ---------------------------------------------------------------------------
// App flow
// ---------------------------------------------------------------------------
pm_require_method('POST');
pm_require_app_key();

$identifier = pm_in_str($in, 'email', 190);
if ($identifier === '') {
    pm_error('VALIDATION', 'Email or phone is required', 200);
}
$identKey = strtolower($identifier);
$code = preg_replace('/\D/', '', pm_in_raw($in, 'code', 16)) ?? '';
$newPassword = pm_in_raw($in, 'new_password', 1024);

if ($code !== '' || $newPassword !== '') {
    // Step 2a: complete with the e-mailed code.
    pm_rate_limit('reset_confirm_ip', pm_client_ip(), 20, 900);
    pm_rate_limit('reset_confirm_id', $identKey, 10, 900);
    if (strlen($newPassword) < 8 || strlen($newPassword) > 128) {
        pm_error('VALIDATION', 'Password must be between 8 and 128 characters.', 200);
    }
    $reset = pm_q_one(
        'SELECT r.id, r.u_uid, r.token_hash, r.code_hash, r.attempts
         FROM password_resets r JOIN unique_user_table u ON u.u_uid = r.u_uid
         WHERE (u.email = ? OR u.phone = ?) AND u.sta = 0 AND r.used_at IS NULL AND r.expires_at > UTC_TIMESTAMP()
         ORDER BY r.id DESC LIMIT 1',
        'ss',
        [$identifier, $identifier]
    );
    $valid = $reset !== null
        && (int)$reset['attempts'] < RESET_MAX_ATTEMPTS
        && hash_equals((string)$reset['code_hash'], hash('sha256', $reset['token_hash'] . '|' . $code));
    if (!$valid) {
        if ($reset !== null) {
            pm_exec('UPDATE password_resets SET attempts = attempts + 1 WHERE id = ?', 'i', [(int)$reset['id']]);
        }
        pm_error('VALIDATION', 'The reset code is invalid or has expired.', 200);
    }
    try {
        reset_apply($reset, $newPassword);
    } catch (PmHttpError $e) {
        pm_error('VALIDATION', 'The reset code is invalid or has expired.', 200);
    }
    pm_rate_limit_clear('login_id', $identKey);
    pm_json(['error' => false, 'message' => 'Your password has been changed. Please sign in.']);
}

// Step 1: request a reset.
pm_rate_limit('reset_req_ip', pm_client_ip(), 10, 900, 'Too many reset requests. Please wait a few minutes.');
pm_rate_limit('reset_req_id', $identKey, 3, 3600, 'Too many reset requests for this account. Please check your email or try again later.');

$user = pm_q_one(
    'SELECT u_uid, fname, email FROM unique_user_table WHERE (email = ? OR phone = ?) AND sta = 0 LIMIT 1',
    'ss',
    [$identifier, $identifier]
);
if ($user === null || !filter_var((string)$user['email'], FILTER_VALIDATE_EMAIL)) {
    reset_generic();
}

$token = bin2hex(random_bytes(32));
$tokenHash = hash('sha256', $token);
$resetCode = pm_random_digits(6);
pm_tx(function () use ($user, $tokenHash, $resetCode) {
    pm_exec('UPDATE password_resets SET used_at = UTC_TIMESTAMP() WHERE u_uid = ? AND used_at IS NULL', 's', [(string)$user['u_uid']]);
    pm_exec(
        'INSERT INTO password_resets (u_uid, token_hash, code_hash, expires_at, ip, created_at)
         VALUES (?, ?, ?, DATE_ADD(UTC_TIMESTAMP(), INTERVAL ? MINUTE), ?, UTC_TIMESTAMP())',
        'sssis',
        [(string)$user['u_uid'], $tokenHash, hash('sha256', $tokenHash . '|' . $resetCode), RESET_TTL_MIN, pm_client_ip()]
    );
});

$link = pm_public_base_url() . 'reset_pwd.php?token=' . $token;
$name = (string)$user['fname'];
$email = (string)$user['email'];
pm_defer(static function () use ($email, $name, $link, $resetCode): void {
    $inner = '<p>Hello ' . pm_mail_e($name) . ',</p>'
        . '<p>We received a request to reset your Pick Me password. If you did not make this request, you can ignore this email — your password will not change.</p>'
        . '<p style="text-align:center;margin:24px 0;"><a href="' . pm_mail_e($link) . '" style="background:#ffc107;color:#222;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:bold;">Reset password</a></p>'
        . '<p>Or enter this code in the app:</p>'
        . '<p style="font-size:24px;font-weight:bold;letter-spacing:6px;text-align:center;background:#f9f9f9;padding:12px;">' . pm_mail_e($resetCode) . '</p>'
        . '<p>This link and code expire in ' . RESET_TTL_MIN . ' minutes and can be used once.</p><p>The Pick Me Team</p>';
    pm_mail_send($email, $name, 'Reset your Pick Me password', pm_mail_layout('Password reset request', $inner),
        "Reset your Pick Me password: $link\nCode: $resetCode\nThis expires in " . RESET_TTL_MIN . ' minutes.');
});
pm_activity((string)$user['u_uid'], 'Password reset requested');

reset_generic();
