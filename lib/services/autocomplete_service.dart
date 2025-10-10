// lib/screens/home/services/autocomplete_service.dart
// Google Places (Autocomplete + FindPlace + Details)

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../screens/state/home_models.dart';

class AutocompleteService {
  final void Function(String, [Object?])? logger;
  AutocompleteService({this.logger});
  void _log(String m, [Object? d]) => logger?.call(m, d);

  Uri _autoUri({
    required String apiKey,
    required String input,
    required String sessionToken,
    String? country,
    LatLng? origin,
    bool relaxedTypes = false,
  }) {
    final buf = StringBuffer(
        'https://maps.googleapis.com/maps/api/place/autocomplete/json')
      ..write('?input=${Uri.encodeComponent(input)}')
      ..write('&key=$apiKey')
      ..write('&sessiontoken=$sessionToken')
      ..write('&language=en');
    if (!relaxedTypes) buf.write('&types=address');
    if (country != null && country.isNotEmpty) {
      buf.write('&components=country:$country');
    }
    if (origin != null) {
      buf
        ..write('&origin=${origin.latitude},${origin.longitude}')
        ..write('&locationbias=circle:50000@${origin.latitude},${origin.longitude}');
    }
    return Uri.parse(buf.toString());
  }

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
    final r = await http.get(uri);
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
      final sf = (p['structured_formatting'] as Map?) ?? const {};
      final main = (sf['main_text'] as String?) ?? '';
      final secondary = (sf['secondary_text'] as String?) ?? '';
      final desc = (p['description'] as String?) ?? '';
      final pid = (p['place_id'] as String?) ?? '';
      final dist = (p['distance_meters'] is int) ? p['distance_meters'] as int : null;
      if (pid.isEmpty) continue;
      out.add(Suggestion(
        description: desc,
        placeId: pid,
        mainText: main,
        secondaryText: secondary,
        distanceMeters: dist,
      ));
    }
    return AutoResult(out, status, err);
  }

  Future<List<Suggestion>> findPlaceText({
    required String input,
    required String apiKey,
    LatLng? origin,
  }) async {
    final sb = StringBuffer(
        'https://maps.googleapis.com/maps/api/place/findplacefromtext/json')
      ..write('?input=${Uri.encodeComponent(input)}')
      ..write('&inputtype=textquery')
      ..write('&fields=place_id,name,formatted_address,geometry/location')
      ..write('&language=en')
      ..write('&key=$apiKey');
    if (origin != null) {
      sb.write(
          '&locationbias=circle:50000@${origin.latitude},${origin.longitude}');
    }
    final uri = Uri.parse(sb.toString());
    _log('FindPlace GET', uri.toString());
    final r = await http.get(uri);
    _log('FindPlace status', r.statusCode);
    if (r.statusCode != 200) return const [];

    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final candidates =
        (j['candidates'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

    final out = <Suggestion>[];
    for (final c in candidates) {
      final name = (c['name'] as String?) ?? '';
      final addr = (c['formatted_address'] as String?) ?? '';
      final pid = (c['place_id'] as String?) ?? '';
      if (pid.isEmpty) continue;
      out.add(Suggestion(
        description: addr.isNotEmpty ? '$name, $addr' : name,
        placeId: pid,
        mainText: name.isNotEmpty ? name : addr,
        secondaryText: addr,
        distanceMeters: null,
      ));
    }
    return out;
  }

  Future<PlaceDetails> placeDetails({
    required String placeId,
    required String sessionToken,
    required String apiKey,
  }) async {
    final uri = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/details/json'
          '?place_id=${Uri.encodeComponent(placeId)}'
          '&fields=geometry/location'
          '&key=$apiKey'
          '&sessiontoken=$sessionToken',
    );
    _log('PlaceDetails GET', uri.toString());
    final r = await http.get(uri);
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
  }
}
