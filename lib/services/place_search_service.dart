import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../shared/models/stop.dart';
import '../shared/theme/app_theme.dart';

/// Adds Malaysian place/address suggestions to the official transit stops.
class PlaceSearchService {
  PlaceSearchService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<List<Stop>> search(String query, {LatLng? near}) async {
    if (query.trim().length < 3) return const [];
    final params = <String, String>{
      'q': query.trim(),
      'limit': '5',
      'lang': 'en',
      'bbox': '99.6,0.8,119.3,7.5',
    };
    if (near != null) {
      params['lat'] = near.latitude.toString();
      params['lon'] = near.longitude.toString();
      params['zoom'] = '12';
    }
    final response = await _client
        .get(Uri.https('photon.komoot.io', '/api/', params), headers: const {
      'User-Agent': 'Homebound transit safety app',
    }).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return const [];
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final features = body['features'] as List<dynamic>? ?? const [];
    return features
        .map((value) {
          final feature = value as Map<String, dynamic>;
          final properties =
              feature['properties'] as Map<String, dynamic>? ?? {};
          final geometry = feature['geometry'] as Map<String, dynamic>? ?? {};
          final coordinates =
              geometry['coordinates'] as List<dynamic>? ?? const [];
          if (coordinates.length < 2) return null;
          final parts = <String>[
            properties['name'] as String? ?? '',
            properties['street'] as String? ?? '',
            properties['district'] as String? ?? '',
            properties['city'] as String? ?? '',
            properties['state'] as String? ?? '',
          ].where((part) => part.trim().isNotEmpty).toSet().toList();
          return Stop(
            name: parts.join(', '),
            platform: 'Place or address',
            position: LatLng(
              (coordinates[1] as num).toDouble(),
              (coordinates[0] as num).toDouble(),
            ),
            timeToDeparture: Duration.zero,
            urgency: ServiceUrgency.onTime,
            transportMode: 'Place',
            hasDepartureData: false,
          );
        })
        .whereType<Stop>()
        .toList();
  }
}
