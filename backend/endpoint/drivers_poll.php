<?php
declare(strict_types=1);

header('Content-Type: application/json');
require_once '../unique/unique_con.php';
require_once 'auth.php';
require_once '../unique/unique_code.php';
require_once '../unique/unique_gtm.php';
require_once '../unique/unique_func.php';
require_once 'activities.php';

$headers = function_exists('apache_request_headers') ? apache_request_headers() : array();
$token = isset($headers['Authorization']) ? $headers['Authorization'] : '';
if (!checkAuthorization($token)) {
  http_response_code(401);
  echo json_encode(['error'=>true,'message'=>'Unauthorized','upserts'=>[],'deletes'=>[]]); exit;
}

$raw = file_get_contents('php://input');
$in  = strlen(trim((string)$raw)) ? json_decode($raw,true) : $_POST;
if (!is_array($in)) $in = $_POST;
$cursor = (int)($in['cursor'] ?? 0);
if ($cursor <= 0) $cursor = time()-5;
$cursor_q = mysqli_real_escape_string($dbconn, (string)$cursor);

$sql = "
SELECT d.id, d.name, d.category, d.rating, d.car_plate,
       l.lat, l.lng, l.heading, UNIX_TIMESTAMP(l.updated_at) AS ts
FROM ride_drivers d
JOIN ride_driver_locations l ON l.driver_id = d.id
WHERE d.is_online = 1
  AND l.updated_at > FROM_UNIXTIME($cursor_q)
  AND NOT EXISTS (
      SELECT 1 FROM ride_rides rr
      WHERE rr.driver_id = d.id
        AND rr.status IN ('accepted','enroute_pickup','arrived_pickup','in_progress','arrived_destination','driver_assigned','in_ride')
  )
LIMIT 500
";
$upq = mysqli_query($dbconn, $sql);
$upserts = [];
while($r = mysqli_fetch_assoc($upq)){
  $upserts[] = [
    'id' => (string)$r['id'],
    'name' => $r['name'],
    'category' => $r['category'],
    'rating' => (float)$r['rating'],
    'car_plate' => $r['car_plate'],
    'lat' => (float)$r['lat'],
    'lng' => (float)$r['lng'],
    'heading' => (float)$r['heading'],
  ];
}

$delq = mysqli_query($dbconn, "
SELECT d.id
FROM ride_drivers d
LEFT JOIN ride_rides rr
  ON rr.driver_id = d.id
 AND rr.status IN ('accepted','enroute_pickup','arrived_pickup','in_progress','arrived_destination','driver_assigned','in_ride')
WHERE d.is_online = 0 OR rr.id IS NOT NULL
");
$deletes = [];
while($r = mysqli_fetch_assoc($delq)){
  $deletes[] = (string)$r['id'];
}

echo json_encode(['error'=>false,'cursor'=>time(),'upserts'=>$upserts,'deletes'=>$deletes]);
