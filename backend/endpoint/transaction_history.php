<?php
declare(strict_types=1);

/**
 * POST transaction_history.php — the session user's wallet ledger (session required).
 * Params: limit (1–100), offset, start_date, end_date (Y-m-d[ H:i:s]), type (plus|minus).
 * Index: idx_uat_user_id (user_uid, id) — see db/migrations/001_security.sql.
 */

require_once __DIR__ . '/security.php';

$uid = pm_require_session();
$in = pm_input();

$limit = pm_in_int($in, 'limit', 50, 1, 100);
$offset = pm_in_int($in, 'offset', 0, 0, 100000);
$startDate = pm_in_str($in, 'start_date', 32);
$endDate = pm_in_str($in, 'end_date', 32);
$type = pm_in_enum($in, 'type', ['plus', 'minus'], '');

$where = 'user_uid = ?';
$types = 's';
$params = [$uid];
$validDate = static fn(string $d): bool => (bool)preg_match('/^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}(:\d{2})?)?$/', $d) && strtotime($d) !== false;
if ($startDate !== '' && $endDate !== '' && $validDate($startDate) && $validDate($endDate)) {
    $where .= ' AND datetime BETWEEN ? AND ?';
    $types .= 'ss';
    $params[] = date('Y-m-d H:i:s', (int)strtotime($startDate));
    $params[] = strlen($endDate) === 10 ? $endDate . ' 23:59:59' : date('Y-m-d H:i:s', (int)strtotime($endDate));
}
if ($type !== '') {
    $where .= ' AND type = ?';
    $types .= 's';
    $params[] = $type;
}

$rows = pm_q_all(
    "SELECT id, descTxt, datetime, amount, type, pay_mode, staus, reference, int_tran_id, user_tran_id, sup_account, sup_bank, data
     FROM unique_account_table WHERE $where ORDER BY id DESC LIMIT ? OFFSET ?",
    $types . 'ii',
    array_merge($params, [$limit, $offset])
);

function determineTransactionIcon(string $description, string $paymentMode): string
{
    $base = 'https://phantomphones.store/pick_me/img/';
    $map = [
        '9Mobile' => '9mobile-300x300.png', 'Airtel' => 'airtel-300x300.png', 'MTN' => 'mtn-300x300.png', 'GLO' => 'glo-300x300.png',
        'EKO' => 'eko.png', 'SMILE' => 'smile.jpeg', 'swift' => 'swift4g.jpg', 'App' => 'logo.png', 'MONIEPOINT' => 'Moniepoint.jpg',
        'united bank for africa' => 'uba.png', 'kuda' => 'kuda.png', 'opay' => 'opay.jpeg', 'palmpay' => 'palmpay.png', 'wema' => 'wema.png',
        'first bank' => 'firstbank.png', 'fidelity' => 'fidelity.png', 'ENUGU DISCO ELECTRIC' => 'eedc.png', 'Gift' => 'gift.webp',
    ];
    foreach ($map as $keyword => $icon) {
        if (stripos($description, $keyword) !== false) {
            return $base . $icon;
        }
    }
    return $paymentMode === 'bank_transfer' ? 'N/A' : $base . 'default-icon.png';
}

$transactions = [];
foreach ($rows as $row) {
    $decoded = json_decode((string)$row['data'], true);
    $ts = strtotime((string)$row['datetime']);
    $transactions[] = [
        'id'             => (int)$row['id'],
        'title'          => ucwords(strtolower((string)$row['descTxt'])),
        'datetime'       => $ts ? date('c', $ts) : date('c'),
        'amount'         => (float)$row['amount'],
        'type'           => (string)$row['type'],
        'payment_mode'   => $row['pay_mode'],
        'status'         => $row['staus'],
        'reference'      => $row['reference'],
        'recharge_token' => is_array($decoded) && isset($decoded['data']['recharge_token']) ? (string)$decoded['data']['recharge_token'] : 'N/A',
        'transaction_id' => ($row['int_tran_id'] ?? '') !== '' && $row['int_tran_id'] !== null ? $row['int_tran_id'] : $row['user_tran_id'],
        'recipient'      => ['account' => $row['sup_account'] ?: 'N/A', 'bank' => $row['sup_bank'] ?: 'N/A'],
        'icon'           => determineTransactionIcon((string)$row['descTxt'], (string)$row['pay_mode']),
    ];
}

// Aggregate summary in SQL (no full-table transfer to PHP).
$sum = pm_q_one(
    "SELECT COUNT(*) AS n, COALESCE(SUM(ABS(amount)), 0) AS total,
            COALESCE(SUM(CASE WHEN type = 'plus' THEN amount ELSE 0 END), 0) AS inflow,
            COALESCE(SUM(CASE WHEN type = 'plus' THEN 0 ELSE amount END), 0) AS outflow
     FROM unique_account_table WHERE user_uid = ?",
    's',
    [$uid]
);

pm_json([
    'error'   => false,
    'message' => 'Transactions fetched successfully',
    'data'    => [
        'summary' => [
            'total_transactions' => (int)$sum['n'],
            'total_amount'       => (float)$sum['total'],
            'inflow'             => (float)$sum['inflow'],
            'outflow'            => (float)$sum['outflow'],
        ],
        'transactions' => $transactions,
        'pagination'   => ['total' => (int)$sum['n'], 'limit' => $limit, 'offset' => $offset],
    ],
]);
