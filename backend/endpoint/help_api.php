<?php
declare(strict_types=1);

/**
 * GET|POST help_api.php — PUBLIC (app key). action=get_help (default): support contacts, FAQ categories, FAQs.
 */

require_once __DIR__ . '/security.php';

pm_require_method('GET', 'POST');
pm_require_app_key();

$action = strtolower(pm_in_str(array_merge($_GET, pm_input()), 'action', 40, 'get_help'));
if ($action !== 'get_help') {
    pm_error('VALIDATION', 'Invalid action requested.', 200, ['data' => null]);
}

$contacts = pm_q_one('SELECT support_email, support_phone, whatsapp_number FROM support_contacts ORDER BY id ASC LIMIT 1');
$categories = array_map(
    static fn($r) => ['id' => (int)$r['id'], 'name' => (string)$r['name']],
    pm_q_all('SELECT id, name FROM faq_categories ORDER BY sort_order ASC, id ASC')
);
$faqs = array_map(
    static fn($r) => ['id' => (int)$r['id'], 'category_id' => (int)$r['category_id'], 'question' => (string)$r['question'], 'answer' => (string)$r['answer']],
    pm_q_all('SELECT id, category_id, question, answer FROM faqs ORDER BY id ASC')
);

pm_json([
    'error'   => false,
    'message' => 'Help data retrieved successfully.',
    'data'    => [
        'contacts' => [
            'email'    => (string)($contacts['support_email'] ?? pm_env('SUPPORT_EMAIL', 'support@realpickme.com')),
            'phone'    => (string)($contacts['support_phone'] ?? ''),
            'whatsapp' => (string)($contacts['whatsapp_number'] ?? ''),
        ],
        'categories' => $categories,
        'faqs'       => $faqs,
    ],
]);
