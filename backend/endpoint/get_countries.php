<?php
// 1. SET UP ERROR LOGGING
// This will write all errors to 'error_log.txt' in the same folder as this script
ini_set('log_errors', 1);
ini_set('error_log', dirname(__FILE__) . '/error_log.txt');
error_reporting(E_ALL);

header('Content-Type: application/json; charset=utf-8');

$db_path = '../unique/unique_con.php';
if (!file_exists($db_path)) {
    error_log("CRITICAL ERROR: Cannot find database file at $db_path");
    http_response_code(500);
    echo json_encode(['error' => true, 'message' => 'Database file missing. Check error_log.txt']);
    exit;
}

require_once $db_path;

if (!$dbconn) {
    error_log("CRITICAL ERROR: Database connection failed - " . mysqli_connect_error());
    http_response_code(500);
    echo json_encode(['error' => true, 'message' => 'Database connection failed. Check error_log.txt']);
    exit;
}

// 2. THE EMOJI FIX (CRITICAL)
// You MUST set the charset to utf8mb4 so PHP can handle the flag emojis. 
// Without this, json_encode() silently fails and returns a blank page!
mysqli_set_charset($dbconn, "utf8mb4");

// 3. FETCH COUNTRIES
$query = "SELECT id, name, iso2, phonecode, emoji FROM unique_countries ORDER BY name ASC";
$result = mysqli_query($dbconn, $query);

$countries = array();
if ($result) {
    while($row = mysqli_fetch_assoc($result)) {
        $countries[] = $row;
    }

    if (count($countries) === 0) {
        error_log("WARNING: Query succeeded but unique_countries table is empty.");
        http_response_code(200);
        echo json_encode(['error' => true, 'message' => 'Table is empty.']);
        exit;
    }

    // Try to encode to JSON
    $json_output = json_encode(array(
        'error' => false,
        'data' => $countries
    ));
    
    // 4. CATCH JSON CRASHES
    // If it fails to encode, log the exact reason instead of showing a blank page
    if ($json_output === false) {
        $json_error = json_last_error_msg();
        error_log("JSON ENCODE ERROR: " . $json_error);
        http_response_code(500);
        echo json_encode(['error' => true, 'message' => 'JSON Encode Error: ' . $json_error]);
        exit;
    }

    // Output success
    http_response_code(200);
    echo $json_output;

} else {
    $sql_error = mysqli_error($dbconn);
    error_log("SQL ERROR: " . $sql_error);
    http_response_code(500);
    echo json_encode(['error' => true, 'message' => 'SQL Error occurred. Check error_log.txt']);
}
?>