// lib/screens/home/services/autocomplete_service.dart
// Premium Google Places Service (Autocomplete + FindPlace + Details)
// Architected for high-performance ride-hailing queries.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../screens/state/home_models.dart';

class AutocompleteService {
  final void Function(String, [Object?])? logger;
  static const Duration _timeout = Duration(seconds: 8);
  static const String _authority = 'maps.googleapis.com';

  AutocompleteService({this.logger});

  void _log(String m, [Object? d]) => logger?.call(m, d);

  /// Builds a robust, properly encoded URI for the Autocomplete API.
  Uri _autoUri({
    required String apiKey,
    required String input,
    required String sessionToken,
    String? country,
    LatLng? origin,
    bool relaxedTypes = false,
  }) {
    final queryParams = <String, String>{
      'input': input,
      'key': apiKey,
      'sessiontoken': sessionToken,
      'language': 'en',
    };

    // By default, a ride-hailing app should search for establishments AND geocodes.
    // Restricting to 'address' hides airports, malls, and landmarks.
    if (!relaxedTypes) {
      queryParams['types'] = 'geocode|establishment';
    }

    if (country != null && country.trim().isNotEmpty) {
      queryParams['components'] = 'country:${country.trim().toLowerCase()}';
    }

    if (origin != null) {
      queryParams['origin'] = '${origin.latitude},${origin.longitude}';
      // Tightly bias results to a 30km radius around the user's current location
      queryParams['locationbias'] = 'circle:30000@${origin.latitude},${origin.longitude}';
    }

    return Uri.https(_authority, '/maps/api/place/autocomplete/json', queryParams);
  }

  /// Fetches rich autocomplete suggestions.
  Future<AutoResult> autocomplete({
    required String input,
    required String sessionToken,
    required String apiKey,
    String? country,
    LatLng? origin,
    bool relaxedTypes = false,
  }) async {
    final uri = _autoUri(
      apiKey: apiKey,
      input: input,
      sessionToken: sessionToken,
      country: country,
      origin: origin,
      relaxedTypes: relaxedTypes,
    );

    _log('Autocomplete GET', uri.toString());

    try {
      final r = await http.get(uri).timeout(_timeout);
      _log('Autocomplete status', r.statusCode);

      if (r.statusCode != 200) {
        return AutoResult([], 'HTTP_${r.statusCode}', 'HTTP error');
      }

      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final status = j['status'] as String?;
      final err = j['error_message'] as String?;
      final preds = (j['predictions'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

      final out = <Suggestion>[];
      for (final p in preds) {
        final pid = (p['place_id'] as String?) ?? '';
        if (pid.isEmpty) continue;

        final desc = (p['description'] as String?) ?? '';
        final sf = (p['structured_formatting'] as Map?) ?? const {};

        // Intelligent fallback parsing if structured_formatting is incomplete
        String main = (sf['main_text'] as String?) ?? '';
        String secondary = (sf['secondary_text'] as String?) ?? '';

        if (main.isEmpty && desc.isNotEmpty) {
          final parts = desc.split(',');
          main = parts.first.trim();
          secondary = parts.length > 1 ? parts.skip(1).join(',').trim() : '';
        }

        final dist = (p['distance_meters'] is int) ? p['distance_meters'] as int : null;

        out.add(Suggestion(
          description: desc,
          placeId: pid,
          mainText: main,
          secondaryText: secondary,
          distanceMeters: dist,
        ));
      }
      return AutoResult(out, status, err);

    } on TimeoutException {
      _log('Autocomplete Timeout');
      return AutoResult([], 'TIMEOUT', 'Request timed out');
    } on SocketException {
      _log('Autocomplete Network Error');
      return AutoResult([], 'NETWORK_ERROR', 'No internet connection');
    } catch (e) {
      _log('Autocomplete Exception', e.toString());
      return AutoResult([], 'EXCEPTION', e.toString());
    }
  }

  /// Fallback search using FindPlaceFromText for edge-case queries.
  Future<List<Suggestion>> findPlaceText({
    required String input,
    required String apiKey,
    LatLng? origin,
  }) async {
    final queryParams = <String, String>{
      'input': input,
      'inputtype': 'textquery',
      'fields': 'place_id,name,formatted_address,geometry/location',
      'language': 'en',
      'key': apiKey,
    };

    if (origin != null) {
      queryParams['locationbias'] = 'circle:30000@${origin.latitude},${origin.longitude}';
    }

    final uri = Uri.https(_authority, '/maps/api/place/findplacefromtext/json', queryParams);

    _log('FindPlace GET', uri.toString());

    try {
      final r = await http.get(uri).timeout(_timeout);
      _log('FindPlace status', r.statusCode);

      if (r.statusCode != 200) return const [];

      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final candidates = (j['candidates'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

      final out = <Suggestion>[];
      for (final c in candidates) {
        final pid = (c['place_id'] as String?) ?? '';
        if (pid.isEmpty) continue;

        final name = (c['name'] as String?) ?? '';
        final addr = (c['formatted_address'] as String?) ?? '';

        out.add(Suggestion(
          description: addr.isNotEmpty && name.isNotEmpty ? '$name, $addr' : (name.isNotEmpty ? name : addr),
          placeId: pid,
          mainText: name.isNotEmpty ? name : addr,
          secondaryText: name.isNotEmpty ? addr : '',
          distanceMeters: null,
        ));
      }
      return out;
    } catch (e) {
      _log('FindPlace Exception', e.toString());
      return const [];
    }
  }

  /// Fetches high-precision coordinates for the finalized place.
  Future<PlaceDetails> placeDetails({
    required String placeId,
    required String sessionToken,
    required String apiKey,
  }) async {
    final queryParams = <String, String>{
      'place_id': placeId,
      'fields': 'geometry/location',
      'key': apiKey,
      'sessiontoken': sessionToken,
    };

    final uri = Uri.https(_authority, '/maps/api/place/details/json', queryParams);

    _log('PlaceDetails GET', uri.toString());

    try {
      final r = await http.get(uri).timeout(_timeout);
      _log('PlaceDetails status', r.statusCode);

      if (r.statusCode != 200) return const PlaceDetails(null);

      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (j['status'] != 'OK') _log('Details.status', j['status']);

      final loc = (j['result']?['geometry']?['location']) as Map?;
      if (loc == null) return const PlaceDetails(null);

      final lat = (loc['lat'] as num?)?.toDouble();
      final lng = (loc['lng'] as num?)?.toDouble();

      if (lat == null || lng == null) return const PlaceDetails(null);
      return PlaceDetails(LatLng(lat, lng));

    } catch (e) {
      _log('PlaceDetails Exception', e.toString());
      return const PlaceDetails(null);
    }
  }
}