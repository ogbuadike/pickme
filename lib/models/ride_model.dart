class Ride {
  final int id; final String status;
  final double pickupLat,pickupLng,destLat,destLng;
  final String? pickupAddress,destAddress;
  final double? userLat,userLng,driverLat,driverLng;
  Ride({
    required this.id, required this.status,
    required this.pickupLat, required this.pickupLng,
    required this.destLat, required this.destLng,
    this.pickupAddress, this.destAddress, this.userLat, this.userLng, this.driverLat, this.driverLng
  });
  factory Ride.fromJson(Map<String,dynamic> j){
    double? d(v)=>v==null?null:double.tryParse(v.toString());
    return Ride(
      id:j['id'], status:j['status'],
      pickupLat:d(j['pickup_lat'])??0, pickupLng:d(j['pickup_lng'])??0,
      destLat:d(j['destination_lat'])??0, destLng:d(j['destination_lng'])??0,
      pickupAddress:j['pickup_address'], destAddress:j['destination_address'],
      userLat:d(j['user_lat']), userLng:d(j['user_lng']),
      driverLat:d(j['driver_lat']), driverLng:d(j['driver_lng']),
    );
  }
}
