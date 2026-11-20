// lib/services/address_resolver_service.dart

import 'package:geocoding/geocoding.dart' as geo;

class AddressResolverService {
  static final Map<String, _AddressCacheItem> _cache =
  <String, _AddressCacheItem>{};

  static const Duration _ttl = Duration(hours: 6);
  static const int _maxCacheSize = 300;

  /// In-flight lookups, so concurrent callers for the same point share one
  /// platform geocoder call.
  static final Map<String, Future<String>> _inflight = <String, Future<String>>{};

  static Future<String> detailedAddressFromLatLng(
      double lat,
      double lng, {
        String fallback = 'Unknown location',
      }) {
    final key = _key(lat, lng);
    final cached = _cache[key];
    if (cached != null && DateTime.now().difference(cached.createdAt) <= _ttl) {
      return Future<String>.value(cached.value);
    }
    final pending = _inflight[key];
    if (pending != null) return pending;

    final f = () async {
      try {
        final placemarks = await geo.placemarkFromCoordinates(lat, lng);
        final first = placemarks.isNotEmpty ? placemarks.first : null;
        final text = formatPlacemark(first, fallback: fallback);
        // Only cache real results: a transient geocoder/network failure must
        // not pin "Unknown location" for hours.
        if (first != null) _put(key, text);
        return text;
      } catch (_) {
        return fallback;
      }
    }();
    _inflight[key] = f;
    // Registered after insertion so even a synchronously-failing lookup is removed.
    f.whenComplete(() => _inflight.remove(key)).ignore();
    return f;
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