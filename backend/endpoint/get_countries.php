<?php
declare(strict_types=1);

/**
 * GET|POST get_countries.php — PUBLIC (app key). Country list for the phone/country picker.
 * Cached by APCu for 1 hour when available.
 */

require_once __DIR__ . '/security.php';

pm_require_method('GET', 'POST');
pm_require_app_key();

$countries = null;
$apcu = function_exists('apcu_fetch') && filter_var(ini_get('apc.enabled'), FILTER_VALIDATE_BOOLEAN);
if ($apcu) {
    $hit = false;
    $countries = apcu_fetch('pickme_countries_v1', $hit);
    if (!$hit) {
        $countries = null;
    }
}
if ($countries === null) {
    $countries = pm_q_all('SELECT id, name, iso2, phonecode, emoji FROM unique_countries ORDER BY name ASC');
    if ($apcu && $countries) {
        apcu_store('pickme_countries_v1', $countries, 3600);
    }
}

if (!$countries) {
    pm_error('SERVER', 'Country list is unavailable.', 200);
}

pm_json(['error' => false, 'data' => $countries]);
