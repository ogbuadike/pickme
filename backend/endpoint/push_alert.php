<?php

ini_set('display_errors', 1);
ini_set('display_startup_errors', 1);
error_reporting(E_ALL);

require 'fcm_vendor/autoload.php';

use Kreait\Firebase\Factory;

// Replace with path to your service account JSON file
$serviceAccountFilePath = 'fcm_vendor/pick-me-fafe2-firebase-adminsdk-fbsvc-4f6ffe4999.json';

if (!file_exists($serviceAccountFilePath)) {
    die('Service account file not found: ' . $serviceAccountFilePath);
}

// Initialize the Firebase Admin SDK
try {
    $factory = (new Factory)->withServiceAccount($serviceAccountFilePath);
    $messaging = $factory->createMessaging();
} catch (Exception $e) {
    die('Error initializing Firebase: ' . $e->getMessage());
}

// Function to send credit alert notification using Firebase Messaging
function credit_alert_app($amount, $user, $is_inapp = false) {
    global $messaging;

    // 1. Data payload (Always sent. Flutter reads this for in-app UI and routing)
    $data = [
        'type' => 'credit_alert',
        'title' => '🎉💸 Credit Alert, Get Your Party Pants On!!!',
        'body' => 'You\'ve just received ₦' . number_format($amount, 2) . '! Time to treat yourself like the financial superstar you are! 💃🕺',
        'is_inapp' => $is_inapp ? 'true' : 'false', // Pass the flag to Flutter
        'click_action' => 'transaction_page', // Used for Flutter routing
        'key2' => 'transaction',
    ];

    // 2. FCM message payload base
    $message = [
        'token' => $user,
        'data' => $data,
    ];

    // 3. If it is NOT an in-app message, append the 'notification' object.
    // This forces the OS to show a system banner when the app is in the background.
    if (!$is_inapp) {
        $message['notification'] = [
            'title' => $data['title'],
            'body' => $data['body'],
            'sound' => 'default',
        ];
    }

    // 4. Send the notification
    try {
        $response = $messaging->send($message);
        echo 'Credit alert notification sent successfully! Response: ' . json_encode($response);
    } catch (Exception $e) {
        echo 'Error sending credit alert: ' . $e->getMessage();
    }
}








// --- TESTING ---
// System Pop-up (Default behavior)
// credit_alert_app(50000, 'USER_TOKEN'); 

// In-App Message Only
// credit_alert_app(50000, 'USER_TOKEN', true); 

?>