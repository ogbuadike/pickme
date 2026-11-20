<?php
header('Content-Type: application/json');

require_once '../unique/unique_con.php';
require_once 'auth.php';
require_once '../unique/unique_code.php';
require_once '../unique/unique_gtm.php';
require_once '../unique/unique_func.php';
require_once 'activities.php';

// 1. Authorization Check
$headers = function_exists('apache_request_headers') ? apache_request_headers() : array();
$token = isset($headers['Authorization']) ? $headers['Authorization'] : '';

$authorized = checkAuthorization($token);
if (!$authorized) {
    http_response_code(401);
    echo json_encode(array(
        'error' => true,
        'message' => 'Unauthorized access',
        'data' => null,
    ));
    exit();
}

// 2. Helper Functions
function sanitizeInput($input) {
    return trim(htmlspecialchars((string)$input, ENT_QUOTES, 'UTF-8'));
}

function jsonResponse($payload, $statusCode = 200) {
    http_response_code($statusCode);
    echo json_encode($payload);
    exit();
}

// 3. Core Logic
function fetchHelpData() {
    global $dbconn;

    // Fetch Support Contacts
    $contactQ = mysqli_query($dbconn, "SELECT * FROM support_contacts LIMIT 1");
    $contacts = $contactQ ? mysqli_fetch_assoc($contactQ) : null;

    // Fetch FAQ Categories
    $catQ = mysqli_query($dbconn, "SELECT id, name FROM faq_categories ORDER BY sort_order ASC");
    $categories = array();
    if ($catQ) {
        while ($row = mysqli_fetch_assoc($catQ)) {
            $categories[] = array(
                'id' => (int)$row['id'],
                'name' => $row['name']
            );
        }
    }

    // Fetch FAQs
    $faqQ = mysqli_query($dbconn, "SELECT id, category_id, question, answer FROM faqs ORDER BY id ASC");
    $faqs = array();
    if ($faqQ) {
        while ($row = mysqli_fetch_assoc($faqQ)) {
            $faqs[] = array(
                'id' => (int)$row['id'],
                'category_id' => (int)$row['category_id'],
                'question' => $row['question'],
                'answer' => $row['answer']
            );
        }
    }

    return array(
        'error' => false,
        'message' => 'Help data retrieved successfully.',
        'data' => array(
            'contacts' => array(
                'email' => isset($contacts['support_email']) ? $contacts['support_email'] : 'support@phantomphones.store',
                'phone' => isset($contacts['support_phone']) ? $contacts['support_phone'] : '+2348000000000',
                'whatsapp' => isset($contacts['whatsapp_number']) ? $contacts['whatsapp_number'] : '+2348000000000'
            ),
            'categories' => $categories,
            'faqs' => $faqs
        )
    );
}

// 4. Execution block
try {
    // Allows the API to be called via POST or GET (e.g. action=get_help)
    $action = isset($_REQUEST['action']) ? strtolower(sanitizeInput($_REQUEST['action'])) : 'get_help';

    if ($action === 'get_help') {
        jsonResponse(fetchHelpData(), 200);
    } else {
        throw new Exception('Invalid action requested.');
    }

} catch (Exception $e) {
    jsonResponse(array(
        'error' => true,
        'message' => $e->getMessage(),
        'data' => null,
    ), 200);
}