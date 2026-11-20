<?php
declare(strict_types=1);

/**
 * POST account_delete.php — permanently deletes the session user's account (contract §6).
 * Params: password (required). Revokes all sessions, anonymises PII, removes uploaded
 * documents, marks the account deleted (sta = 2). Refused while a trip is active.
 */

require_once __DIR__ . '/security.php';
require_once __DIR__ . '/activities.php';

pm_require_method('POST');
$uid = pm_require_session();
$in = pm_input();

pm_json(pm_account_delete($uid, pm_in_raw($in, 'password', 1024)));
