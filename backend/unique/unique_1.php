<?php
declare(strict_types=1);

/**
 * Environment loader.
 *
 * Secrets live in "<DOCUMENT_ROOT>/.required/.env" (one KEY=VALUE per line,
 * '#' comments allowed). The file is parsed once per request and cached.
 * If DOCUMENT_ROOT is unavailable (CLI / cron) PICKME_ENV_FILE may point at
 * the file explicitly. Real process environment variables are used as a
 * fallback so containerised deployments also work.
 */

if (isset($_SERVER['SCRIPT_FILENAME']) && realpath((string)$_SERVER['SCRIPT_FILENAME']) === __FILE__) {
    http_response_code(404);
    exit;
}

if (!function_exists('env_data')) {
    function pm_env_file_path(): string
    {
        $explicit = getenv('PICKME_ENV_FILE');
        if (is_string($explicit) && $explicit !== '') {
            return $explicit;
        }
        $root = (string)($_SERVER['DOCUMENT_ROOT'] ?? '');
        if ($root === '') {
            // backend/unique -> backend -> (document root when deployed as-is)
            $root = dirname(__DIR__);
        }
        return rtrim($root, '/') . '/.required/.env';
    }

    function pm_env_all(): array
    {
        static $cache = null;
        if ($cache !== null) {
            return $cache;
        }
        $cache = [];
        $path = pm_env_file_path();
        $raw = is_readable($path) ? (string)@file_get_contents($path) : '';
        // Editors on Windows/cPanel often save a UTF-8 BOM, which would silently
        // corrupt the first key name (e.g. "\xEF\xBB\xBFAPP_KEY_SHA256").
        if (strncmp($raw, "\xEF\xBB\xBF", 3) === 0) {
            $raw = substr($raw, 3);
        }
        foreach (preg_split('/\r\n|\r|\n/', $raw) ?: [] as $line) {
            $line = trim($line);
            if ($line === '' || $line[0] === '#') {
                continue;
            }
            if (strncmp($line, 'export ', 7) === 0) {
                $line = trim(substr($line, 7));
            }
            $parts = explode('=', $line, 2);
            if (count($parts) !== 2) {
                continue;
            }
            // Strip ordinary and non-breaking spaces pasted from web pages/chat apps.
            $key = trim($parts[0], " \t\u{00A0}");
            $value = trim($parts[1], " \t\u{00A0}");
            $len = strlen($value);
            if ($len >= 2 && (($value[0] === '"' && $value[$len - 1] === '"') || ($value[0] === "'" && $value[$len - 1] === "'"))) {
                $value = substr($value, 1, -1);
            }
            if ($key !== '') {
                $cache[$key] = $value; // last definition wins (matches legacy behaviour)
            }
        }
        return $cache;
    }

    /** Returns the value of an .env key, or '' when missing. */
    function env_data($evn_name): string
    {
        $all = pm_env_all();
        $key = (string)$evn_name;
        if (array_key_exists($key, $all)) {
            return (string)$all[$key];
        }
        $fromProcess = getenv($key);
        return is_string($fromProcess) ? $fromProcess : '';
    }
}

$db_user = env_data('DATAUSER');
$db_name = env_data('DATANAME');
$db_pass = env_data('DATAPASS');

$Host  = env_data('HOST');
$Email = env_data('EMAIL');
$Passw = env_data('EMAIL_PASSWORD');
