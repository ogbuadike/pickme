<?php
declare(strict_types=1);

/**
 * POST user_settings.php — the session user's app settings (session required).
 * action=get_settings | update_setting (setting_key ∈ whitelist, setting_value)
 * Table user_settings_table is created by db/migrations/001_security.sql (no DDL at runtime).
 */

require_once __DIR__ . '/security.php';

$uid = pm_require_session();
$in = pm_input();
$action = pm_in_str($in, 'action', 40);

const SETTINGS_BOOL_KEYS = ['push_notif', 'sms_notif', 'email_promos', 'loc_access', 'share_ride'];
const SETTINGS_TEXT_KEYS = ['language' => ['English', 'French', 'Spanish', 'Igbo', 'Hausa', 'Yoruba', 'Pidgin'], 'theme' => ['System', 'Light', 'Dark']];

pm_exec('INSERT IGNORE INTO user_settings_table (user_uid) VALUES (?)', 's', [$uid]);

if ($action === 'get_settings') {
    $s = pm_q_one('SELECT push_notif, sms_notif, email_promos, loc_access, share_ride, language, theme FROM user_settings_table WHERE user_uid = ? LIMIT 1', 's', [$uid]);
    $appSettings = [
        'terms_of_service_url' => 'https://phantomphones.store/pick_me/terms',
        'privacy_policy_url'   => 'https://phantomphones.store/pick_me/privacy',
    ];
    foreach (pm_q_all("SELECT setting_key, setting_value FROM app_settings WHERE setting_key IN ('terms_of_service_url', 'privacy_policy_url')") as $row) {
        $appSettings[$row['setting_key']] = $row['setting_value'];
    }
    if ($s === null) {
        pm_error('SERVER', 'Failed to load settings', 200);
    }
    pm_json([
        'error'    => false,
        'message'  => 'Settings retrieved',
        'settings' => [
            'push_notif'   => (int)$s['push_notif'],
            'sms_notif'    => (int)$s['sms_notif'],
            'email_promos' => (int)$s['email_promos'],
            'loc_access'   => (int)$s['loc_access'],
            'share_ride'   => (int)$s['share_ride'],
            'language'     => (string)$s['language'],
            'theme'        => (string)$s['theme'],
        ],
        'app_settings' => $appSettings,
    ]);
}

if ($action === 'update_setting') {
    pm_require_method('POST');
    $key = pm_in_str($in, 'setting_key', 40);
    $val = pm_in_str($in, 'setting_value', 40);
    if (in_array($key, SETTINGS_BOOL_KEYS, true)) {
        $bool = in_array(strtolower($val), ['1', 'true', 'on', 'yes'], true) ? 1 : 0;
        // Column name comes from the whitelist above, never from raw input.
        pm_exec('UPDATE user_settings_table SET `' . $key . '` = ? WHERE user_uid = ?', 'is', [$bool, $uid]);
        pm_json(['error' => false, 'message' => 'Setting updated']);
    }
    if (isset(SETTINGS_TEXT_KEYS[$key])) {
        $match = null;
        foreach (SETTINGS_TEXT_KEYS[$key] as $opt) {
            if (strcasecmp($opt, $val) === 0) {
                $match = $opt;
            }
        }
        if ($match === null) {
            pm_error('VALIDATION', 'Invalid setting value', 200);
        }
        pm_exec('UPDATE user_settings_table SET `' . $key . '` = ? WHERE user_uid = ?', 'ss', [$match, $uid]);
        pm_json(['error' => false, 'message' => 'Setting updated']);
    }
    pm_error('VALIDATION', 'Invalid setting key', 200);
}

pm_error('VALIDATION', 'Invalid action', 200);
