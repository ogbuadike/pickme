<?php
declare(strict_types=1);

/**
 * GET/POST delete_account.php — public web page for account deletion requests.
 *
 * Google Play requires a web URL where users can delete their account (and data)
 * without reinstalling the app. Apple accepts in-app deletion (account_delete.php),
 * but this page also serves as the "how to delete" link in App Store Connect.
 *
 * The user proves ownership with email/phone + password. Deletion reuses the same
 * pm_account_delete() as the in-app flow (sessions revoked, PII anonymised,
 * documents removed, refused while a trip is active). Rate limited per IP.
 */

require_once __DIR__ . '/security.php';
require_once __DIR__ . '/activities.php';

function delacct_html(string $title, string $body, int $status = 200): void
{
    if (!headers_sent()) {
        http_response_code($status);
        header('Content-Type: text/html; charset=utf-8');
        header('Cache-Control: no-store');
        header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");
    }
    $t = htmlspecialchars($title, ENT_QUOTES, 'UTF-8');
    echo '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
        . '<title>' . $t . ' - Pick Me</title></head>'
        . '<body style="font-family:Segoe UI,Roboto,Arial,sans-serif;background:#f4f4f4;margin:0;padding:24px;color:#222;">'
        . '<div style="max-width:460px;margin:40px auto;background:#fff;border-radius:12px;padding:28px;">'
        . '<h1 style="font-size:22px;margin-top:0;">' . $t . '</h1>' . $body . '</div></body></html>';
    exit;
}

function delacct_form(string $error = '', string $identifier = ''): string
{
    $err = $error !== '' ? '<p style="color:#c00;">' . htmlspecialchars($error, ENT_QUOTES, 'UTF-8') . '</p>' : '';
    $id = htmlspecialchars($identifier, ENT_QUOTES, 'UTF-8');
    $input = 'width:100%;box-sizing:border-box;padding:10px;margin:6px 0 14px;border:1px solid #ccc;border-radius:8px;';
    return '<p>You can permanently delete your Pick Me account here, or in the app under <b>Profile &rarr; Delete Account</b>.</p>'
        . '<p><b>What is deleted:</b> your name, email, phone number, profile photo, saved settings, push tokens, '
        . 'login sessions and any driver documents you uploaded.</p>'
        . '<p><b>What is kept:</b> trip and wallet transaction records, with your personal details removed, '
        . 'because tax, accounting and anti-fraud rules require them.</p>'
        . '<p>Your wallet balance is not refunded automatically. Withdraw it or contact support before you delete. '
        . 'Accounts with an active trip cannot be deleted until the trip ends.</p>'
        . $err
        . '<form method="post" action="delete_account.php" autocomplete="off">'
        . '<label>Email or phone number<br><input name="identifier" maxlength="190" required value="' . $id . '" style="' . $input . '"></label>'
        . '<label>Password<br><input type="password" name="password" maxlength="128" required style="' . $input . '"></label>'
        . '<label style="display:block;margin-bottom:16px;"><input type="checkbox" name="confirm" value="1" required> '
        . 'I understand this permanently deletes my account and cannot be undone.</label>'
        . '<button type="submit" style="background:#d32f2f;color:#fff;border:0;border-radius:8px;padding:12px 20px;font-weight:bold;">Delete my account</button>'
        . '</form>';
}

$method = strtoupper((string)($_SERVER['REQUEST_METHOD'] ?? 'GET'));
if ($method !== 'POST') {
    delacct_html('Delete your Pick Me account', delacct_form());
}

pm_rate_limit('delete_web_ip', pm_client_ip(), 10, 3600);

$in = pm_input();
$identifier = trim(pm_in_str($in, 'identifier', 190));
$password = pm_in_raw($in, 'password', 1024);

if ($identifier === '' || $password === '' || (string)($in['confirm'] ?? '') !== '1') {
    delacct_html('Delete your Pick Me account', delacct_form('Please fill in every field and tick the confirmation box.', $identifier), 422);
}

// Same generic message for "no such user" and "wrong password" (no account enumeration).
$generic = 'The email/phone or password is incorrect.';
$user = pm_q_one(
    'SELECT u_uid FROM unique_user_table WHERE (email = ? OR phone = ?) AND sta <> 2 LIMIT 1',
    'ss',
    [$identifier, $identifier]
);
if ($user === null) {
    password_verify($password, '$2y$10$usesomesillystringfore7hnbRJHxXVLeakoG8K30oukPsA.ztMG'); // equalise timing
    delacct_html('Delete your Pick Me account', delacct_form($generic, $identifier), 403);
}

try {
    pm_account_delete((string)$user['u_uid'], $password);
} catch (PmHttpError $e) {
    $msg = $e->apiCode === 'FORBIDDEN' ? $generic : $e->getMessage();
    delacct_html('Delete your Pick Me account', delacct_form($msg, $identifier), $e->httpStatus);
}

delacct_html(
    'Account deleted',
    '<p>Your Pick Me account has been permanently deleted and you have been signed out on all devices.</p>'
    . '<p>You can uninstall the app. Thank you for riding with us.</p>'
);
