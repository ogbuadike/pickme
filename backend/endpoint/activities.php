<?php
declare(strict_types=1);

/**
 * Pick Me domain helpers: activity log, wallet ledger, image storage, notifications.
 * Library file — not an endpoint (direct access returns 404 and is denied in .htaccess).
 */

if (isset($_SERVER['SCRIPT_FILENAME']) && realpath((string)$_SERVER['SCRIPT_FILENAME']) === __FILE__) {
    http_response_code(404);
    exit;
}

require_once __DIR__ . '/security.php';
require_once (defined('PM_UNIQUE_DIR') ? PM_UNIQUE_DIR : (is_file(__DIR__ . '/unique/unique_1.php') ? __DIR__ . '/unique' : __DIR__ . '/../unique')) . '/pm_mail.php';
require_once __DIR__ . '/push_alert.php';

// ---------------------------------------------------------------------------
// Activity log
// ---------------------------------------------------------------------------
function pm_activity(string $uid, string $activity): void
{
    try {
        $now = pm_legacy_now();
        pm_exec(
            'INSERT INTO unique_activities (activity_id, activity, uid, time, date, datetime) VALUES (?, ?, ?, ?, ?, ?)',
            'ssssss',
            [pm_random_digits(8), mb_substr($activity, 0, 1000), $uid, $now['time'], $now['date'], $now['datetime']]
        );
    } catch (Throwable $e) {
        pm_log('warning', 'activity log failed', ['msg' => $e->getMessage()]);
    }
}

/** Backward-compatible alias used by older code paths. */
function Activities($activity, $my_user_uid): void
{
    pm_activity((string)$my_user_uid, (string)$activity);
}

// ---------------------------------------------------------------------------
// Wallet (contract §8): atomic conditional updates; call inside pm_tx()
// ---------------------------------------------------------------------------
function pm_wallet_balance(string $uid, bool $forUpdate = false): ?float
{
    $row = pm_q_one('SELECT bal FROM unique_user_table WHERE u_uid = ? LIMIT 1' . ($forUpdate ? ' FOR UPDATE' : ''), 's', [$uid]);
    return $row === null ? null : (float)$row['bal'];
}

/** Credits $amount (> 0). Returns false when the user does not exist. */
function pm_wallet_credit(string $uid, float $amount): bool
{
    if (!is_finite($amount) || $amount <= 0) {
        return true;
    }
    $amount = round($amount, 2);
    return pm_exec('UPDATE unique_user_table SET bal = bal + ? WHERE u_uid = ? LIMIT 1', 'ds', [$amount, $uid]) === 1;
}

/** Debits $amount only if the balance covers it. Returns false on insufficient funds / unknown user. */
function pm_wallet_debit(string $uid, float $amount): bool
{
    if (!is_finite($amount) || $amount <= 0) {
        return true;
    }
    $amount = round($amount, 2);
    return pm_exec('UPDATE unique_user_table SET bal = bal - ? WHERE u_uid = ? AND bal >= ? LIMIT 1', 'dsd', [$amount, $uid, $amount]) === 1;
}

/** Appends a ledger row to unique_account_table. $type is 'plus' | 'minus'. */
function pm_ledger_add(string $uid, float $amount, string $type, string $description, string $reference, string $payMode = 'wallet', string $status = 'successful', string $data = '', string $userTranId = ''): void
{
    $now = pm_legacy_now();
    pm_exec(
        'INSERT INTO unique_account_table
            (descTxt, reference, user_tran_id, user_uid, rec_uid, type, amount, staus, pay_mode, datetime, date, time, data, sup_account, sup_bank)
         VALUES (?, ?, ?, ?, \'admin\', ?, ?, ?, ?, ?, ?, ?, ?, \'\', \'\')',
        'sssssdssssss',
        [mb_substr($description, 0, 500), $reference, $userTranId, $uid, $type === 'plus' ? 'plus' : 'minus', round($amount, 2), $status, $payMode, $now['datetime'], $now['date'], $now['time'], $data]
    );
}

// ---------------------------------------------------------------------------
// Image storage — re-encodes to WebP with GD (strips any embedded payload),
// random unguessable file names, size/dimension limits.
// ---------------------------------------------------------------------------
/**
 * @param string $field      $_FILES key
 * @param string $relDir     directory relative to this endpoint folder, e.g. 'uploads/packages/<uid>'
 * @return string|null       public URL, or null when optional and absent
 */
function pm_store_image(string $field, string $relDir, bool $required = true, int $maxBytes = 8388608, int $maxDim = 1200, int $minDim = 0): ?string
{
    $label = str_replace('_', ' ', $field);
    if (!isset($_FILES[$field]) || !is_array($_FILES[$field]) || ($_FILES[$field]['error'] ?? UPLOAD_ERR_NO_FILE) === UPLOAD_ERR_NO_FILE) {
        if ($required) {
            pm_fail('VALIDATION', 'Missing required upload: ' . $label . '.', 200);
        }
        return null;
    }
    $file = $_FILES[$field];
    if (is_array($file['error']) || (int)$file['error'] !== UPLOAD_ERR_OK || !is_uploaded_file((string)$file['tmp_name'])) {
        pm_fail('VALIDATION', 'Upload failed for ' . $label . '.', 200);
    }
    if ((int)$file['size'] <= 0 || (int)$file['size'] > $maxBytes) {
        pm_fail('VALIDATION', 'File too large for ' . $label . '.', 200);
    }
    $tmp = (string)$file['tmp_name'];
    $info = @getimagesize($tmp);
    if (!$info || empty($info[0]) || empty($info[1])) {
        pm_fail('VALIDATION', 'Invalid image file uploaded for ' . $label . '.', 200);
    }
    [$w, $h] = [(int)$info[0], (int)$info[1]];
    if ($w * $h > 40000000) {
        pm_fail('VALIDATION', 'Image resolution too large for ' . $label . '.', 200);
    }
    if ($minDim > 0 && ($w < $minDim || $h < $minDim)) {
        pm_fail('VALIDATION', 'Image dimensions are too small', 200);
    }
    switch ($info['mime'] ?? '') {
        case 'image/jpeg':
            $img = @imagecreatefromjpeg($tmp);
            break;
        case 'image/png':
            $img = @imagecreatefrompng($tmp);
            break;
        case 'image/webp':
            $img = function_exists('imagecreatefromwebp') ? @imagecreatefromwebp($tmp) : false;
            break;
        case 'image/gif':
            $img = @imagecreatefromgif($tmp);
            break;
        default:
            $img = false;
    }
    if (!$img) {
        pm_fail('VALIDATION', 'Unsupported image format for ' . $label . '. Please use JPG, PNG or WEBP.', 200);
    }
    if ($w > $maxDim || $h > $maxDim) {
        $ratio = $w / $h;
        $nw = $ratio >= 1 ? $maxDim : max(1, (int)round($maxDim * $ratio));
        $nh = $ratio >= 1 ? max(1, (int)round($maxDim / $ratio)) : $maxDim;
        $dst = imagecreatetruecolor($nw, $nh);
        imagealphablending($dst, false);
        imagesavealpha($dst, true);
        imagefilledrectangle($dst, 0, 0, $nw, $nh, imagecolorallocatealpha($dst, 255, 255, 255, 127));
        imagecopyresampled($dst, $img, 0, 0, 0, 0, $nw, $nh, $w, $h);
        imagedestroy($img);
        $img = $dst;
    } elseif (!imageistruecolor($img)) {
        imagepalettetotruecolor($img);
    }

    $relDir = trim(preg_replace('#[^A-Za-z0-9_/\-]#', '', $relDir) ?? '', '/');
    if ($relDir === '' || strpos($relDir, '..') !== false) {
        imagedestroy($img);
        throw new RuntimeException('invalid upload directory');
    }
    $absDir = __DIR__ . '/' . $relDir;
    if (!is_dir($absDir) && !@mkdir($absDir, 0755, true) && !is_dir($absDir)) {
        imagedestroy($img);
        throw new RuntimeException('cannot create upload directory');
    }
    $name = preg_replace('/[^a-z0-9_]/', '', strtolower($field)) . '_' . bin2hex(random_bytes(16)) . '.webp';
    $ok = imagewebp($img, $absDir . '/' . $name, 80);
    imagedestroy($img);
    if (!$ok) {
        throw new RuntimeException('webp encode failed');
    }
    return pm_public_base_url() . $relDir . '/' . $name;
}

/** Deletes a file previously returned by pm_store_image() (only inside our upload folders). */
function pm_delete_stored_file(?string $url): void
{
    if (!$url) {
        return;
    }
    $base = pm_public_base_url();
    if (strpos($url, $base) !== 0) {
        return;
    }
    $rel = substr($url, strlen($base));
    if (!preg_match('#^(uploads|img)/[A-Za-z0-9_/\-]+\.(webp|jpg|jpeg|png)$#', $rel) || strpos($rel, '..') !== false) {
        return;
    }
    $abs = __DIR__ . '/' . $rel;
    if (is_file($abs)) {
        @unlink($abs);
    }
}

/** Safe per-user folder segment. */
function pm_uid_dir(string $uid): string
{
    $safe = preg_replace('/[^A-Za-z0-9_-]/', '', $uid) ?? '';
    return $safe !== '' ? $safe : 'unknown_user';
}

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------
function pm_user_contact(string $uid): ?array
{
    return pm_q_one('SELECT u_uid, fname, lname, email FROM unique_user_table WHERE u_uid = ? LIMIT 1', 's', [$uid]);
}

function email_credit_account(string $to, string $userName, string $payMethod, float $amount, float $balance): bool
{
    $inner = '<p>Dear ' . pm_mail_e($userName) . ',</p>'
        . '<p>Your Pick Me wallet has been credited with <b>NGN ' . pm_mail_e(number_format($amount, 2)) . '</b> via ' . pm_mail_e($payMethod) . '.</p>'
        . '<table role="presentation" cellpadding="8" cellspacing="0" style="border-collapse:collapse;width:100%;max-width:420px;font-size:14px;">'
        . '<tr><td style="border-bottom:1px solid #eee;color:#555;">Amount</td><td style="border-bottom:1px solid #eee;text-align:right;">NGN ' . pm_mail_e(number_format($amount, 2)) . '</td></tr>'
        . '<tr><td style="border-bottom:1px solid #eee;color:#555;">Transaction type</td><td style="border-bottom:1px solid #eee;text-align:right;">Credit</td></tr>'
        . '<tr><td style="border-bottom:1px solid #eee;color:#555;">Payment method</td><td style="border-bottom:1px solid #eee;text-align:right;">' . pm_mail_e($payMethod) . '</td></tr>'
        . '<tr><td style="color:#555;">Current balance</td><td style="text-align:right;">NGN ' . pm_mail_e(number_format($balance, 2)) . '</td></tr>'
        . '</table>'
        . '<p>If you did not expect this transaction, please contact support.</p><p>The Pick Me Team</p>';
    return pm_mail_send($to, $userName, 'Wallet credit NGN ' . number_format($amount, 2) . ' - Pick Me', pm_mail_layout('Wallet credited', $inner));
}

// ---------------------------------------------------------------------------
// Account deletion (contract §6) — revoke sessions, anonymise PII, mark deleted (sta = 2).
// Ledger rows (unique_account_table) and ride rows are retained for accounting, without PII.
// ---------------------------------------------------------------------------
function pm_account_delete(string $uid, string $password): array
{
    pm_rate_limit('account_delete', $uid, 5, 3600, 'Too many attempts. Please try again later.');

    $user = pm_q_one('SELECT u_uid, pass_code, sta, b_logo FROM unique_user_table WHERE u_uid = ? LIMIT 1', 's', [$uid]);
    if ($user === null) {
        pm_fail('NOT_FOUND', 'Account not found.', 404);
    }
    if ($password === '') {
        pm_fail('VALIDATION', 'Please confirm your password to delete your account.', 422);
    }
    [$ok] = pm_password_check($password, (string)$user['pass_code']);
    if (!$ok) {
        pm_fail('FORBIDDEN', 'Password is incorrect.', 403);
    }

    $driver = pm_driver_for_user($uid);
    $driverId = $driver !== null && $driver['id'] !== null ? (int)$driver['id'] : 0;

    $activeAsRider = pm_q_one(
        'SELECT id FROM ride_rides WHERE rider_id = ? AND status IN (' . pm_in_placeholders(PM_RIDE_ACTIVE_STATUSES) . ') LIMIT 1',
        's' . str_repeat('s', count(PM_RIDE_ACTIVE_STATUSES)),
        array_merge([$uid], PM_RIDE_ACTIVE_STATUSES)
    );
    $activeAsDriver = $driverId > 0 ? pm_q_one(
        'SELECT id FROM ride_rides WHERE driver_id = ? AND status IN (' . pm_in_placeholders(PM_RIDE_ACTIVE_STATUSES) . ') LIMIT 1',
        'i' . str_repeat('s', count(PM_RIDE_ACTIVE_STATUSES)),
        array_merge([$driverId], PM_RIDE_ACTIVE_STATUSES)
    ) : null;
    if ($activeAsRider || $activeAsDriver) {
        pm_fail('CONFLICT', 'Please finish or cancel your active trip before deleting your account.', 409);
    }

    $files = [(string)$user['b_logo']];
    if ($driver !== null) {
        $docs = pm_q_one(
            'SELECT o.license_front_url, o.license_back_url, o.nin_front_url, o.nin_back_url, o.vehicle_angled_url, o.vehicle_front_url,
                    o.vehicle_back_url, o.vehicle_side_url, d.avatar_url, d.car_image_url
             FROM ride_driver_onboarding o LEFT JOIN ride_drivers d ON d.id = o.driver_id
             WHERE o.id = ?',
            'i',
            [(int)$driver['onboarding_id']]
        );
        foreach ((array)$docs as $u) {
            $files[] = (string)$u;
        }
    }

    pm_tx(function () use ($uid, $driverId) {
        pm_exec(
            "UPDATE ride_rides SET status = 'canceled', canceled_at = NOW(), cancel_reason = 'account_deleted'
             WHERE rider_id = ? AND status = 'searching'",
            's',
            [$uid]
        );
        pm_exec(
            "UPDATE unique_user_table SET
                fname = 'Deleted', lname = 'User', oname = '', email = CONCAT('deleted+', u_uid, '@invalid.local'), phone = '',
                pass_code = '', access = '', base_location = '', last_location = '', b_logo = '', b_name = NULL, b_abou = NULL,
                b_addr = NULL, b_city = NULL, b_state = NULL, b_s_linkedin = NULL, b_s_twit = NULL, b_s_face = NULL, b_s_github = NULL,
                Account_Name = '', AID = '', account = '', us = '', ng = '', emergency_contact = '', sta = 2, deleted_at = NOW()
             WHERE u_uid = ? LIMIT 1",
            's',
            [$uid]
        );
        pm_exec(
            'UPDATE ride_rides SET pickup_text = NULL, dest_text = NULL, recipient_phone = NULL, instructions = NULL,
                    errand_instructions = NULL, package_image = NULL, delivery_otp = NULL
             WHERE rider_id = ?',
            's',
            [$uid]
        );
        if ($driverId > 0) {
            pm_exec(
                "UPDATE ride_drivers SET name = 'Deleted driver', phone = NULL, nin = NULL, bank_name = NULL, account_number = NULL,
                        photo_url = NULL, vehicle_images = NULL, car_image_url = NULL, avatar_url = NULL, is_online = 0
                 WHERE id = ? LIMIT 1",
                'i',
                [$driverId]
            );
            pm_exec('DELETE FROM ride_driver_locations WHERE driver_id = ?', 'i', [$driverId]);
            pm_exec('DELETE FROM ride_driver_location_events WHERE driver_id = ?', 'i', [$driverId]);
        }
        pm_exec(
            "UPDATE ride_driver_onboarding SET legal_full_name = 'Deleted', email = NULL,
                    phone = CONCAT('deleted-', id), nin = CONCAT('deleted-', id),
                    license_front_url = NULL, license_back_url = NULL, nin_front_url = NULL, nin_back_url = NULL,
                    vehicle_angled_url = NULL, vehicle_front_url = NULL, vehicle_back_url = NULL, vehicle_side_url = NULL,
                    submitted_images = NULL, status = 'rejected', admin_note = 'account deleted'
             WHERE user_uid = ?",
            's',
            [$uid]
        );
        pm_exec('DELETE FROM app_users WHERE uid = ?', 's', [$uid]);
        pm_exec('DELETE FROM user_settings_table WHERE user_uid = ?', 's', [$uid]);
        pm_exec('DELETE FROM app_notifications WHERE u_uid = ?', 's', [$uid]);
        pm_exec('DELETE FROM password_resets WHERE u_uid = ?', 's', [$uid]);
        pm_session_revoke_all($uid, 'account_deleted');
    });

    pm_defer(static function () use ($files): void {
        foreach ($files as $f) {
            pm_delete_stored_file($f);
        }
    });
    pm_log('info', 'account deleted');
    unset($GLOBALS['PM_SESSION']);
    return ['error' => false, 'message' => 'Account completely deleted.'];
}
