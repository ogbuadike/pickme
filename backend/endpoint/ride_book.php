<?php
declare(strict_types=1);

require_once 'ride_api_bootstrap.php';

ride_authorize();
$in = ride_input();

$riderId     = ride_s($in['rider_id'] ?? $in['uid'] ?? $in['user_id'] ?? '');
$driverId    = ride_i($in['driver_id'] ?? 0, 0);
$offerId     = ride_s($in['offer_id'] ?? '');
$provider    = ride_s($in['provider'] ?? 'PickMe', 'PickMe');
$category    = ride_s($in['category'] ?? 'Standard', 'Standard');
$vehicleType = ride_s($in['vehicle_type'] ?? $in['vehicle'] ?? 'car', 'car');
$currency    = ride_s($in['currency'] ?? 'NGN', 'NGN');
$payMethod   = ride_s($in['pay_method'] ?? 'cash', 'cash');
$price       = ride_f($in['price'] ?? $in['price_total'] ?? $in['price_ngn'] ?? 0, 0.0);
$estimated   = ride_f($in['estimated_total'] ?? $in['price_total'] ?? $price, 0.0);
$baseFare    = ride_f($in['base_fare'] ?? 0, 0.0);
$pricePerKm  = ride_f($in['price_per_km'] ?? 0, 0.0);
$pickupText  = ride_s($in['pickup_text'] ?? '');
$destText    = ride_s($in['destination_text'] ?? $in['dest_text'] ?? '');
$etaMin      = ride_i($in['eta_min'] ?? 0, 0);
$surge       = ride_i($in['surge'] ?? 0, 0);
$seats       = ride_i($in['seats'] ?? 4, 4);
$tripKm      = ride_f($in['trip_km'] ?? 0, 0.0);

// NEW: Catching the Ride Type and Instructions for Campus/Dispatch/SendMe
$rideType    = ride_s($in['ride_type'] ?? 'street_ride', 'street_ride');
$instructions = ride_s($in['instructions'] ?? '');

[$pickupLat, $pickupLng] = ride_parse_latlng(
    $in['pickup'] ?? null,
    $in['pickup_lat'] ?? null,
    $in['pickup_lng'] ?? null
);

[$destLat, $destLng] = ride_parse_latlng(
    $in['destination'] ?? null,
    $in['destination_lat'] ?? null,
    $in['destination_lng'] ?? null
);

$stopsRaw  = $in['stops'] ?? '';
$stopsJson = null;
if (is_array($stopsRaw)) {
    $norm = [];
    foreach ($stopsRaw as $s) {
        if (!is_array($s)) continue;
        $lat = ride_f($s['lat'] ?? $s['latitude'] ?? null, 0.0);
        $lng = ride_f($s['lng'] ?? $s['longitude'] ?? null, 0.0);
        if ($lat == 0.0 && $lng == 0.0) continue;
        $norm[] = ['lat' => $lat, 'lng' => $lng];
    }
    if (!empty($norm)) $stopsJson = json_encode($norm);
} elseif (is_string($stopsRaw) && trim($stopsRaw) !== '') {
    $pieces = explode('|', $stopsRaw);
    $stops  = [];
    foreach ($pieces as $p) {
        if (strpos($p, ',') === false) continue;
        [$la, $lo] = explode(',', $p, 2);
        $stops[] = ['lat' => ride_f($la, 0.0), 'lng' => ride_f($lo, 0.0)];
    }
    if (!empty($stops)) $stopsJson = json_encode($stops);
}

if ($riderId === '') ride_json(['error' => true, 'message' => 'rider_id is required'], 422);
if ($driverId <= 0) ride_json(['error' => true, 'message' => 'driver_id is required'], 422);
if ($pickupLat == 0.0 || $pickupLng == 0.0) ride_json(['error' => true, 'message' => 'pickup coordinates are required'], 422);
if ($destLat == 0.0 || $destLng == 0.0) ride_json(['error' => true, 'message' => 'destination coordinates are required'], 422);

$user = ride_query_one(
    $dbconn,
    "SELECT id, u_uid, fname, lname, email, sta
     FROM unique_user_table
     WHERE u_uid = ?
     LIMIT 1",
    's',
    [$riderId]
);
if (!$user) ride_json(['error' => true, 'message' => 'Rider not found'], 404);
if ((int)($user['sta'] ?? 1) !== 0) ride_json(['error' => true, 'message' => 'Rider account is not active'], 409);

$driver = ride_query_one(
    $dbconn,
    "SELECT id, name, category, vehicle_type, car_plate, rating, is_online, seats, base_fare, price_per_km, currency
     FROM ride_drivers
     WHERE id = ?
     LIMIT 1",
    'i',
    [$driverId]
);
if (!$driver) ride_json(['error' => true, 'message' => 'Driver not found'], 404);
if ((int)$driver['is_online'] !== 1) ride_json(['error' => true, 'message' => 'Driver is offline'], 409);

// Driver becomes busy ONLY after acceptance.
$busy = ride_query_one(
    $dbconn,
    "SELECT id
     FROM ride_rides
     WHERE driver_id = ?
       AND status IN ('accepted','enroute_pickup','arrived_pickup','in_progress','arrived_destination','driver_assigned','in_ride')
     LIMIT 1",
    'i',
    [$driverId]
);
if ($busy) ride_json(['error' => true, 'message' => 'Driver is busy'], 409);

if ($category === '') $category = ride_s($driver['category'] ?? 'Standard', 'Standard');
if ($vehicleType === '') $vehicleType = ride_s($driver['vehicle_type'] ?? 'car', 'car');
if ($seats <= 0) $seats = ride_i($driver['seats'] ?? 4, 4);
if ($baseFare <= 0) $baseFare = ride_f($driver['base_fare'] ?? 0, 0.0);
if ($pricePerKm <= 0) $pricePerKm = ride_f($driver['price_per_km'] ?? 0, 0.0);
if ($estimated <= 0 && $tripKm > 0 && $pricePerKm > 0) $estimated = $baseFare + ($pricePerKm * $tripKm);
if ($currency === '') $currency = ride_s($driver['currency'] ?? 'NGN', 'NGN');

$stmt = ride_exec(
    $dbconn,
    "INSERT INTO ride_rides
        (rider_id, driver_id, offer_id, status, provider, category, vehicle_type, seats, price, estimated_total, base_fare, price_per_km, currency, pay_method,
         pickup_lat, pickup_lng, pickup_text, dest_lat, dest_lng, dest_text, stops_json, eta_min, surge, ride_type, instructions)
     VALUES
        (?, ?, ?, 'searching', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    'sissssiddddssddsddssiiss', // Updated to 24 parameters including the two new strings (ss)
    [
        $riderId,
        $driverId,
        $offerId,
        $provider,
        $category,
        $vehicleType,
        $seats,
        $price,
        $estimated,
        $baseFare,
        $pricePerKm,
        $currency,
        $payMethod,
        $pickupLat,
        $pickupLng,
        $pickupText,
        $destLat,
        $destLng,
        $destText,
        $stopsJson,
        $etaMin,
        $surge,
        $rideType,
        $instructions
    ]
);

$rideId = (int)mysqli_insert_id($dbconn);
mysqli_stmt_close($stmt);

$ride = ride_fetch_ride($dbconn, $rideId);
$driverLive = ride_fetch_driver($dbconn, $driverId);
$payload = ride_payload($ride, $driverLive);
$payload['message'] = 'Ride request created and sent to the driver queue.';
$payload['displayMessage'] = 'Ride request sent. Waiting for driver acceptance.';
$payload['queue_state'] = 'pending_driver_acceptance';

ride_json($payload, 200);