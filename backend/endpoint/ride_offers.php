<?php
header('Content-Type: application/json');
require_once '../unique/unique_con.php';
require_once 'auth.php';
require_once '../unique/unique_code.php';
require_once '../unique/unique_gtm.php';
require_once '../unique/unique_func.php';
require_once 'activities.php';

$headers = apache_request_headers();
$token = isset($headers['Authorization']) ? $headers['Authorization'] : '';
if (!checkAuthorization($token)) {
  http_response_code(401);
  echo json_encode(['error'=>true,'message'=>'Unauthorized','offers'=>[]]); exit;
}

function num($v,$d=0){ return is_numeric($v)? (float)$v : (float)$d; }

$raw = file_get_contents('php://input');
$in  = strlen($raw)? json_decode($raw,true) : $_POST;

$o = isset($in['origin']) ? $in['origin'] : [];
$d = isset($in['destination']) ? $in['destination'] : [];
$olat = num($o['lat'] ?? null);
$olng = num($o['lng'] ?? null);
$dlat = num($d['lat'] ?? null);
$dlng = num($d['lng'] ?? null);
$radius = num($in['radius_km'] ?? 50);

if (!$olat || !$olng || !$dlat || !$dlng) {
  echo json_encode(['error'=>true,'message'=>'origin/destination required','offers'=>[]]); exit;
}

$olat_q = mysqli_real_escape_string($dbconn, $olat);
$olng_q = mysqli_real_escape_string($dbconn, $olng);
$radius_q = mysqli_real_escape_string($dbconn, $radius);

// pickup->dest distance for fare
$distPickDest = 6371 * 2 * asin(sqrt(
  pow(sin(deg2rad(($dlat-$olat)/2)),2) +
  cos(deg2rad($olat))*cos(deg2rad($dlat))*pow(sin(deg2rad(($dlng-$olng)/2)),2)
));

$sql = "
SELECT d.id, d.name, d.category, d.rating, d.car_plate, l.lat, l.lng,
(6371 * 2 * ASIN(SQRT(POWER(SIN(RADIANS($olat_q - l.lat)/2),2) +
 COS(RADIANS($olat_q))*COS(RADIANS(l.lat))*POWER(SIN(RADIANS($olng_q - l.lng)/2),2)))) AS distance_km
FROM ride_drivers d
JOIN ride_driver_locations l ON l.driver_id = d.id
WHERE d.is_online = 1
HAVING distance_km <= $radius_q
ORDER BY distance_km ASC
LIMIT 30
";
$q = mysqli_query($dbconn, $sql);

$offers = [];
while($r = mysqli_fetch_assoc($q)){
  $cat = $r['category'];
  $mult = ($cat==='XL')?1.8:(($cat==='Comfort')?1.35:1.0);
  $base = 500.0; $perKm = 120.0;
  $price = $base + ($distPickDest * $perKm * $mult);
  $etaMin = max(1, (int)round(((float)$r['distance_km']) / 0.4)); // ~24km/h

  $offers[] = [
    'id'          => $r['id'].'-'.$cat,
    'provider'    => 'Pick Me',
    'category'    => $cat,
    'price'       => round($price,0),
    'eta_min'     => $etaMin,
    'seats'       => ($cat==='XL'?6:4),
    'surge'       => false,
    'driver_id'   => (string)$r['id'],
    'driver_name' => $r['name'],
    'rating'      => (float)$r['rating'],
    'car_plate'   => $r['car_plate'],
  ];
}

echo json_encode(['error'=>false,'offers'=>$offers]);
