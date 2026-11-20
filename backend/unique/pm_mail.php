<?php
declare(strict_types=1);

/**
 * Transactional e-mail for Pick Me (PHPMailer over SMTP).
 *
 * .env keys: HOST (SMTP host), EMAIL (SMTP user), EMAIL_PASSWORD,
 *            optional SMTP_PORT (default 587), SMTP_SECURE (tls|ssl, default tls),
 *            MAIL_FROM (default EMAIL), MAIL_FROM_NAME (default "Pick Me"),
 *            SUPPORT_EMAIL (shown in footers, default MAIL_FROM).
 *
 * All values interpolated into templates MUST go through pm_mail_e().
 */

use PHPMailer\PHPMailer\PHPMailer;

if (isset($_SERVER['SCRIPT_FILENAME']) && realpath((string)$_SERVER['SCRIPT_FILENAME']) === __FILE__) {
    http_response_code(404);
    exit;
}

require_once __DIR__ . '/unique_1.php';
require_once __DIR__ . '/mail/PHPMailer-master/src/Exception.php';
require_once __DIR__ . '/mail/PHPMailer-master/src/PHPMailer.php';
require_once __DIR__ . '/mail/PHPMailer-master/src/SMTP.php';

function pm_mail_e($value): string
{
    return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE | ENT_HTML5, 'UTF-8');
}

/** Neutral Pick Me HTML layout. $innerHtml must already be escaped/trusted markup. */
function pm_mail_layout(string $heading, string $innerHtml): string
{
    $year = gmdate('Y');
    $support = pm_mail_e(env_data('SUPPORT_EMAIL') ?: (env_data('MAIL_FROM') ?: env_data('EMAIL')));
    $site = pm_mail_e(env_data('PUBLIC_SITE_URL') ?: 'https://realpickme.com');
    $logo = pm_mail_e((env_data('PUBLIC_SITE_URL') ?: 'https://realpickme.com') . '/logo.png');
    $heading = pm_mail_e($heading);

    return <<<HTML
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>{$heading}</title></head>
<body style="margin:0;padding:0;background:#f2f2f2;font-family:Segoe UI,Roboto,Arial,sans-serif;color:#333;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f2f2f2;padding:20px 0;">
    <tr><td align="center">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:12px;overflow:hidden;">
        <tr><td style="background:#ffc107;padding:24px;text-align:center;">
          <img src="{$logo}" alt="Pick Me" style="max-width:120px;height:auto;">
        </td></tr>
        <tr><td style="padding:28px;">
          <h1 style="font-size:22px;margin:0 0 16px 0;color:#222;">{$heading}</h1>
          {$innerHtml}
        </td></tr>
        <tr><td style="background:#f8f9fa;padding:20px;text-align:center;font-size:12px;color:#777;">
          Need help? Contact <a href="mailto:{$support}" style="color:#007bff;">{$support}</a><br>
          &copy; {$year} Pick Me &middot; <a href="{$site}" style="color:#007bff;">{$site}</a>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>
HTML;
}

/**
 * Sends one e-mail. Never throws, never echoes. Returns true on success.
 */
function pm_mail_send(string $to, string $toName, string $subject, string $html, string $altText = ''): bool
{
    $to = trim($to);
    if ($to === '' || !filter_var($to, FILTER_VALIDATE_EMAIL)) {
        return false;
    }
    $host = env_data('HOST');
    $user = env_data('EMAIL');
    if ($host === '' || $user === '') {
        error_log('[pickme] mail not configured (HOST/EMAIL missing)');
        return false;
    }

    $mail = new PHPMailer(true);
    try {
        $mail->SMTPDebug  = 0;
        $mail->isSMTP();
        $mail->Host       = $host;
        $mail->SMTPAuth   = true;
        $mail->Username   = $user;
        $mail->Password   = env_data('EMAIL_PASSWORD');
        $mail->SMTPSecure = (strtolower(env_data('SMTP_SECURE')) === 'ssl') ? PHPMailer::ENCRYPTION_SMTPS : PHPMailer::ENCRYPTION_STARTTLS;
        $mail->Port       = (int)(env_data('SMTP_PORT') ?: 587);
        $mail->Timeout    = 10;
        $mail->CharSet    = 'UTF-8';

        $mail->setFrom(env_data('MAIL_FROM') ?: $user, env_data('MAIL_FROM_NAME') ?: 'Pick Me');
        $mail->addAddress($to, $toName);
        $mail->isHTML(true);
        $mail->Subject = $subject;
        $mail->Body    = $html;
        $mail->AltBody = $altText !== '' ? $altText : trim(html_entity_decode(strip_tags($html), ENT_QUOTES, 'UTF-8'));
        $mail->send();
        return true;
    } catch (Throwable $e) {
        error_log('[pickme] mail send failed: ' . $mail->ErrorInfo);
        return false;
    }
}
