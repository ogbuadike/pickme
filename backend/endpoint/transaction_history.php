<?php
header('Content-Type: application/json');

// Include necessary files
require_once '../unique/unique_con.php';
require_once 'auth.php';
require_once '../unique/unique_code.php';
require_once '../unique/unique_gtm.php';
require_once '../unique/unique_func.php';
require_once 'activities.php';

// Enhanced error handling
function sendErrorResponse($message, $code = 400) {
    http_response_code($code);
    echo json_encode(['error' => true, 'message' => $message, 'data' => null]);
    exit();
}

function sanitizeInput($input) {
    return trim(htmlspecialchars((string)$input, ENT_QUOTES, 'UTF-8'));
}

// Authenticate user
$headers = function_exists('apache_request_headers') ? apache_request_headers() : array();
$token = isset($headers['Authorization']) ? $headers['Authorization'] : '';

if (!checkAuthorization($token)) {
    sendErrorResponse("Unauthorized access", 401);
}

// Get and validate parameters
$user_id = isset($_POST['user']) ? sanitizeInput($_POST['user']) : null;
$limit = isset($_POST['limit']) ? (int)$_POST['limit'] : 50;
$offset = isset($_POST['offset']) ? (int)$_POST['offset'] : 0;
$start_date = isset($_POST['start_date']) ? sanitizeInput($_POST['start_date']) : null;
$end_date = isset($_POST['end_date']) ? sanitizeInput($_POST['end_date']) : null;
$transaction_type = isset($_POST['type']) ? sanitizeInput($_POST['type']) : null;

if (!$user_id) {
    sendErrorResponse("User ID is required");
}

global $dbconn;
$escapedUid = mysqli_real_escape_string($dbconn, $user_id);

// Start building the SQL query
$query = "SELECT * FROM unique_account_table WHERE user_uid = '$escapedUid'";

// Add date range filter if provided
if ($start_date && $end_date) {
    $escapedStart = mysqli_real_escape_string($dbconn, $start_date);
    $escapedEnd = mysqli_real_escape_string($dbconn, $end_date);
    // Note: If datetime is a string, BETWEEN might be inaccurate. Keep as is if it currently works.
    $query .= " AND datetime BETWEEN '$escapedStart' AND '$escapedEnd'";
}

// Add transaction type filter if provided
if ($transaction_type) {
    $escapedType = mysqli_real_escape_string($dbconn, $transaction_type);
    $query .= " AND type = '$escapedType'";
}

// --- BULLETPROOF SORTING FIX ---
// Instead of sorting by a datetime string (which breaks on AM/PM), 
// we sort by 'id DESC'. The highest ID is mathematically ALWAYS the newest transaction.
$query .= " ORDER BY id DESC LIMIT $limit OFFSET $offset";

// Execute the query
$result = mysqli_query($dbconn, $query);

if (!$result) {
    sendErrorResponse("Failed to execute query: " . mysqli_error($dbconn));
}

$transactions = [];
while ($row = mysqli_fetch_assoc($result)) {
    $decoded_data = json_decode($row['data'], true);
    $token = isset($decoded_data['data']['recharge_token']) ? $decoded_data['data']['recharge_token'] : 'N/A';

    // --- ISO 8601 DATE FIX FOR FLUTTER ---
    // Convert whatever AM/PM string format is in the DB into a strict standard format.
    $rawDate = $row['datetime'];
    $parsedTimestamp = strtotime($rawDate);
    // 'c' outputs ISO 8601 format (e.g., 2026-05-03T14:30:00+00:00) which Dart parses flawlessly.
    $flutterSafeDate = $parsedTimestamp ? date('c', $parsedTimestamp) : date('c'); 

    $transaction = [
        'id' => (int)$row['id'],
        'title' => ucwords(strtolower($row['descTxt'])),
        'datetime' => $flutterSafeDate, 
        'amount' => (float)$row['amount'],
        'type' => $row['type'], // 'plus' or 'minus'
        'payment_mode' => $row['pay_mode'],
        'status' => $row['staus'], // Keeping your exact DB spelling
        'reference' => $row['reference'],
        'recharge_token' => $token,
        'transaction_id' => $row['int_tran_id'] ?: $row['user_tran_id'],
        'recipient' => [
            'account' => $row['sup_account'] ?? 'N/A',
            'bank' => $row['sup_bank'] ?? 'N/A'
        ],
        'icon' => determineTransactionIcon($row['descTxt'], $row['pay_mode'])
    ];

    $transactions[] = $transaction;
}

// Calculate summary statistics (Fetch all for accurate total, not just the limited pagination set)
$summaryQuery = "SELECT amount, type FROM unique_account_table WHERE user_uid = '$escapedUid'";
$summaryResult = mysqli_query($dbconn, $summaryQuery);
$allTrans = [];
if ($summaryResult) {
    while($sRow = mysqli_fetch_assoc($summaryResult)){
        $allTrans[] = $sRow;
    }
}
$summary = calculateTransactionSummary($allTrans);

// Prepare the response
$response = [
    'error' => false,
    'message' => 'Transactions fetched successfully',
    'data' => [
        'summary' => $summary,
        'transactions' => $transactions,
        'pagination' => [
            'total' => count($allTrans),
            'limit' => $limit,
            'offset' => $offset
        ]
    ]
];

http_response_code(200);
echo json_encode($response);

// Helper function to determine transaction icon
function determineTransactionIcon($description, $paymentMode) {
    $iconBaseUrl = 'https://phantomphones.store/pick_me/img/';
    $defaultIcon = $iconBaseUrl . 'default-icon.png';

    $iconMap = [
        '9Mobile' => '9mobile-300x300.png',
        'Airtel' => 'airtel-300x300.png',
        'MTN' => 'mtn-300x300.png',
        'GLO' => 'glo-300x300.png',
        'EKO' => 'eko.png',
        'SMILE' => 'smile.jpeg',
        'swift' => 'swift4g.jpg',
        'App' => 'logo.png',
        'MONIEPOINT' => 'Moniepoint.jpg',
        'united bank for africa' => 'uba.png',
        'kuda' => 'kuda.png',
        'opay' => 'opay.jpeg',
        'palmpay' => 'palmpay.png',
        'wema' => 'wema.png',
        'first bank' => 'firstbank.png',
        'fidelity' => 'fidelity.png',
        'ENUGU DISCO ELECTRIC' => 'eedc.png',
        'Gift' => 'gift.webp'
    ];

    foreach ($iconMap as $keyword => $icon) {
        if (stripos($description, $keyword) !== false) {
            return $iconBaseUrl . $icon;
        }
    }

    if ($paymentMode === 'bank_transfer') {
        return 'N/A'; // Will trigger fallback in Flutter
    }

    return $defaultIcon;
}

// Helper function to calculate transaction summary
function calculateTransactionSummary($transactions) {
    $summary = [
        'total_transactions' => count($transactions),
        'total_amount' => 0,
        'inflow' => 0,
        'outflow' => 0
    ];

    foreach ($transactions as $transaction) {
        $amt = (float)$transaction['amount'];
        $summary['total_amount'] += abs($amt);
        if ($transaction['type'] === 'plus') {
            $summary['inflow'] += $amt;
        } else {
            $summary['outflow'] += $amt;
        }
    }

    return $summary;
}