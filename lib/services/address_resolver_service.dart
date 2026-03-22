// lib/services/address_resolver_service.dart

import 'package:geocoding/geocoding.dart' as geo;

class AddressResolverService {
  static final Map<String, _AddressCacheItem> _cache =
  <String, _AddressCacheItem>{};

  static const Duration _ttl = Duration(hours: 6);
  static const int _maxCacheSize = 300;

  static Future<String> detailedAddressFromLatLng(
      double lat,
      double lng, {
        String fallback = 'Unknown location',
      }) async {
    final key = _key(lat, lng);
    final now = DateTime.now();

    final cached = _cache[key];
    if (cached != null && now.difference(cached.createdAt) <= _ttl) {
      return cached.value;
    }

    try {
      final placemarks = await geo.placemarkFromCoordinates(lat, lng);
      final text = formatPlacemark(
        placemarks.isNotEmpty ? placemarks.first : null,
        fallback: fallback,
      );

      _put(key, text);
      return text;
    } catch (_) {
      final text = fallback;
      _put(key, text);
      return text;
    }
  }

  static String formatPlacemark(
      geo.Placemark? p, {
        String fallback = 'Unknown location',
      }) {
    if (p == null) return fallback;

    final parts = <String>[];

    void add(String? value) {
      final v = (value ?? '').trim();
      if (v.isEmpty) return;
      if (parts.any((e) => e.toLowerCase() == v.toLowerCase())) return;
      parts.add(v);
    }

    final streetBits = <String>[
      if ((p.subThoroughfare ?? '').trim().isNotEmpty) p.subThoroughfare!.trim(),
      if ((p.thoroughfare ?? '').trim().isNotEmpty) p.thoroughfare!.trim(),
    ];

    final street = streetBits.join(' ').trim();

    add(p.name);
    add(street.isEmpty ? null : street);
    add(p.subLocality);
    add(p.locality);
    add(p.subAdministrativeArea);
    add(p.administrativeArea);

    final postalCountry = <String>[
      if ((p.postalCode ?? '').trim().isNotEmpty) p.postalCode!.trim(),
      if ((p.country ?? '').trim().isNotEmpty) p.country!.trim(),
    ].join(', ').trim();

    add(postalCountry.isEmpty ? null : postalCountry);

    if (parts.isEmpty) return fallback;
    return parts.join(', ');
  }

  static String _key(double lat, double lng) {
    return '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
  }

  static void _put(String key, String value) {
    if (_cache.length >= _maxCacheSize) {
      final oldestKey = _cache.entries
          .reduce((a, b) => a.value.createdAt.isBefore(b.value.createdAt) ? a : b)
          .key;
      _cache.remove(oldestKey);
    }
    _cache[key] = _AddressCacheItem(value, DateTime.now());
  }
}

class _AddressCacheItem {
  final String value;
  final DateTime createdAt;

  const _AddressCacheItem(this.value, this.createdAt);
}