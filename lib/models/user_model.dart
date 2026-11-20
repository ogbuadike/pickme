/// Minimal user model. Parsing is tolerant of the PHP backend returning
/// numbers as strings (and vice versa) and of missing fields.
class AppUser {
  final int id;
  final String name;
  final String email;
  final String type; // user|driver
  final bool isOnline;

  const AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.type,
    required this.isOnline,
  });

  bool get isDriver => type == 'driver';

  factory AppUser.fromJson(Map<String, dynamic> j) {
    final online = j['is_online'];
    return AppUser(
      id: int.tryParse(j['id']?.toString() ?? '') ?? 0,
      name: (j['name'] ?? '').toString(),
      email: (j['email'] ?? '').toString(),
      type: (j['type'] ?? 'user').toString(),
      isOnline: online == true || online == 1 || online == '1',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'type': type,
        'is_online': isOnline ? 1 : 0,
      };
}
