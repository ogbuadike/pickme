<?php
declare(strict_types=1);

header('Content-Type: application/json');

require_once '../unique/unique_con.php';
require_once 'auth.php';
require_once '../unique/unique_code.php';
require_once '../unique/unique_gtm.php';
require_once '../unique/unique_func.php';
require_once 'activities.php';

const SEARCH_RADIUS_KM = 50.0;
const EARTH_RADIUS_KM  = 6371.0;

function num($v, $d = 0.0): float
{
    return is_numeric($v) ? (float)$v : (float)$d;
}

function respond(int $code, array $payload): void
{
    http_response_code($code);
    echo json_encode($payload, JSON_PRETTY_PRINT);
    exit;
}

$headers = function_exists('apache_request_headers')
    ? apache_request_headers()
    : (function_exists('getallheaders') ? getallheaders() : []);

$raw   = file_get_contents('php://input');
$token = $headers['Authorization'] ?? $headers['authorization'] ?? '';

if (!checkAuthorization($token)) {
    respond(401, [
        'error'   => true,
        'message' => 'Unauthorized access',
        'drivers' => [],
    ]);
}

$in = (is_string($raw) && trim($raw) !== '') ? json_decode($raw, true) : $_POST;
if (!is_array($in)) {
    $in = $_POST;
}

$lat      = num($in['lat'] ?? null);
$lng      = num($in['lng'] ?? null);
$trip_km  = num($in['trip_km'] ?? 0, 0.0);
$currency = trim((string)($in['currency'] ?? 'NGN'));

// NEW: Catching the dynamic ride_type requested by the app
$ride_type = trim((string)($in['ride_type'] ?? 'street_ride'));

if ($lat === 0.0 || $lng === 0.0) {
    respond(200, [
        'error'   => true,
        'message' => 'lat/lng required',
        'drivers' => [],
    ]);
}

/*
|--------------------------------------------------------------------------
| Dynamic Radius Binding (Respects Campus Mode 5km radius)
|--------------------------------------------------------------------------
| We use the incoming radius_km from the client, but cap it at SEARCH_RADIUS_KM 
| (50km) to prevent abuse and protect server performance.
*/
$req_radius = num($in['radius_km'] ?? SEARCH_RADIUS_KM);
$radius = ($req_radius > 0 && $req_radius <= SEARCH_RADIUS_KM) ? $req_radius : SEARCH_RADIUS_KM;

/*
|--------------------------------------------------------------------------
| Bounding box pre-filter
|--------------------------------------------------------------------------
| 1 degree latitude ≈ 111.045 km
| longitude delta depends on latitude
*/
$latDelta = $radius / 111.045;
$cosLat   = cos(deg2rad($lat));
$lngDelta = $radius / (111.045 * max(abs($cosLat), 0.000001));

$minLat = $lat - $latDelta;
$maxLat = $lat + $latDelta;
$minLng = $lng - $lngDelta;
$maxLng = $lng + $lngDelta;

$sql = "
SELECT *
FROM (
    SELECT
        d.id,
        d.name,
        d.category,
        d.rating,
        d.car_plate,
        d.phone,
        d.nin,
        d.rank,
        d.completed_trips,
        d.cancelled_trips,
        d.incomplete_trips,
        d.reviews_count,
        d.total_trips,
        d.vehicle_type,
        d.seats,
        d.vehicle_description,
        d.vehicle_images,
        d.car_image_url,
        d.avatar_url,
        d.price_per_km,
        d.base_fare,
        d.currency,
        l.lat,
        l.lng,
        l.heading,
        l.updated_at,
        (
            ? * 2 * ASIN(
                LEAST(
                    1,
                    SQRT(
                        POWER(SIN(RADIANS(? - l.lat) / 2), 2) +
                        COS(RADIANS(?)) * COS(RADIANS(l.lat)) *
                        POWER(SIN(RADIANS(? - l.lng) / 2), 2)
                    )
                )
            )
        ) AS distance_km
    FROM ride_drivers d
    INNER JOIN ride_driver_locations l
        ON l.driver_id = d.id
    WHERE d.is_online = 1
      -- NEW: Smart filtering allowing comma-separated ride_type permissions
      AND FIND_IN_SET(?, IFNULL(d.allowed_ride_types, 'street_ride')) > 0
      AND l.lat IS NOT NULL
      AND l.lng IS NOT NULL
      AND l.lat BETWEEN ? AND ?
      AND l.lng BETWEEN ? AND ?
      AND NOT EXISTS (
          SELECT 1
          FROM ride_rides rr
          WHERE rr.driver_id = d.id
            AND rr.status IN (
                'accepted',
                'enroute_pickup',
                'arrived_pickup',
                'in_progress',
                'arrived_destination',
                'driver_assigned',
                'in_ride'
            )
      )
) AS nearby_drivers
WHERE nearby_drivers.distance_km <= ?
ORDER BY nearby_drivers.distance_km ASC, nearby_drivers.updated_at DESC
LIMIT 200
";

$stmt = mysqli_prepare($dbconn, $sql);

if (!$stmt) {
    respond(200, [
        'error'   => true,
        'message' => 'Failed to prepare driver lookup',
        'drivers' => [],
    ]);
}

$earthRadiusKm = EARTH_RADIUS_KM;
$userLat1      = $lat;
$userLat2      = $lat;
$userLng       = $lng;
$rideTypeParam = $ride_type; // The injected ride type
$minLatParam   = $minLat;
$maxLatParam   = $maxLat;
$minLngParam   = $minLng;
$maxLngParam   = $maxLng;
$radiusParam   = $radius;

// BOUND EXACTLY TO 10 PARAMETERS: 4 Doubles, 1 String, 5 Doubles
mysqli_stmt_bind_param(
    $stmt,
    'ddddsddddd',
    $earthRadiusKm, // d
    $userLat1,      // d
    $userLat2,      // d
    $userLng,       // d
    $rideTypeParam, // s (NEW)
    $minLatParam,   // d
    $maxLatParam,   // d
    $minLngParam,   // d
    $maxLngParam,   // d
    $radiusParam    // d
);

if (!mysqli_stmt_execute($stmt)) {
    mysqli_stmt_close($stmt);
    respond(200, [
        'error'   => true,
        'message' => 'Failed to fetch drivers',
        'drivers' => [],
    ]);
}

$result = mysqli_stmt_get_result($stmt);

if (!$result) {
    mysqli_stmt_close($stmt);
    respond(200, [
        'error'   => true,
        'message' => 'Failed to fetch drivers',
        'drivers' => [],
    ]);
}

$drivers = [];

while ($r = mysqli_fetch_assoc($result)) {
    $dist = isset($r['distance_km']) ? (float)$r['distance_km'] : 0.0;

    // Guard: ensure it respects the dynamic boundary (e.g. 5km for campus, 50km for street)
    if ($dist > $radius) {
        continue;
    }

    $vehicle_images = json_decode((string)($r['vehicle_images'] ?? '[]'), true);
    if (!is_array($vehicle_images)) {
        $vehicle_images = [];
    }

    $car_image_url = (string)($r['car_image_url'] ?? '');
    if ($vehicle_images === [] && $car_image_url !== '') {
        $vehicle_images = [$car_image_url];
    }

    $ppk       = (float)($r['price_per_km'] ?? 0);
    $base      = (float)($r['base_fare'] ?? 0);
    $cur       = (string)($r['currency'] ?? ($currency !== '' ? $currency : 'NGN'));
    $est_total = ($trip_km > 0 && $ppk > 0) ? ($base + ($ppk * $trip_km)) : 0.0;

    $drivers[] = [
        'id'                  => (string)($r['id'] ?? ''),
        'name'                => (string)($r['name'] ?? ''),
        'category'            => (string)($r['category'] ?? ''),
        'rating'              => isset($r['rating']) ? (float)$r['rating'] : 0.0,
        'car_plate'           => (string)($r['car_plate'] ?? ''),
        'lat'                 => isset($r['lat']) ? (float)$r['lat'] : 0.0,
        'lng'                 => isset($r['lng']) ? (float)$r['lng'] : 0.0,
        'heading'             => isset($r['heading']) ? (float)$r['heading'] : 0.0,
        'distance_km'         => round($dist, 3),
        'eta_min'             => max(1, (int)round($dist / 0.4)),
        'vehicle_type'        => (string)($r['vehicle_type'] ?? 'car'),
        'seats'               => (int)($r['seats'] ?? 4),
        'vehicle_images'      => $vehicle_images,
        'vehicle_description' => (string)($r['vehicle_description'] ?? ''),
        'car_image_url'       => $car_image_url,
        'avatar_url'          => (string)($r['avatar_url'] ?? ''),
        'phone'               => (string)($r['phone'] ?? ''),
        'nin'                 => (string)($r['nin'] ?? ''),
        'rank'                => (string)($r['rank'] ?? ''),
        'completed_trips'     => (int)($r['completed_trips'] ?? 0),
        'cancelled_trips'     => (int)($r['cancelled_trips'] ?? 0),
        'incomplete_trips'    => (int)($r['incomplete_trips'] ?? 0),
        'reviews_count'       => (int)($r['reviews_count'] ?? 0),
        'total_trips'         => (int)($r['total_trips'] ?? 0),
        'currency'            => $cur,
        'price_per_km'        => $ppk,
        'base_fare'           => $base,
        'trip_km'             => $trip_km,
        'estimated_total'     => $est_total,
    ];
}

mysqli_free_result($result);
mysqli_stmt_close($stmt);

respond(200, [
    'error'            => false,
    'cursor'           => time(),
    'radius_km'        => $radius, // Returns the dynamic radius applied
    'returned_drivers' => count($drivers),
    'drivers'          => $drivers,
]);