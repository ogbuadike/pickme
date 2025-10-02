class AppUser {
  final int id;
  final String name;
  final String email;
  final String type; // user|driver
  final bool isOnline;
  AppUser({required this.id,required this.name,required this.email,required this.type,required this.isOnline});
  factory AppUser.fromJson(Map<String,dynamic> j)=>AppUser(
      id:j['id'], name:j['name'], email:j['email'], type:j['type'], isOnline:(j['is_online']??0)==1
  );
}
