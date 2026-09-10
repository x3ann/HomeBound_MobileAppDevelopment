import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../shared/models/walking_route.dart';

/// Fetches a pedestrian route that follows mapped roads and paths.
/// The endpoint can be replaced at build time for a production deployment.
class WalkingRouteService {
  WalkingRouteService({http.Client? client})
      : _client = client ?? http.Client();

  static const _defaultEndpoint =
      'https://routing.openstreetmap.de/routed-foot/route/v1/driving';
  static const _endpoint = String.fromEnvironment(
    'WALKING_ROUTER_URL',
    defaultValue: _defaultEndpoint,
  );

  final http.Client _client;

  Future<WalkingRoute> route(LatLng from, LatLng to) async {
    final coordinates =
        '${from.longitude},${from.latitude};${to.longitude},${to.latitude}';
    final uri = Uri.parse('$_endpoint/$coordinates').replace(
      queryParameters: const {
        'overview': 'full',
        'geometries': 'geojson',
        'steps': 'true',
      },
    );
    final response = await _client.get(uri, headers: const {
      'User-Agent': 'Homebound transit safety app',
    }).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Walking route service returned ${response.statusCode}',
        uri,
      );
    }
    return parseResponse(jsonDecode(response.body) as Map<String, dynamic>);
  }

  static WalkingRoute parseResponse(Map<String, dynamic> body) {
    if (body['code'] != 'Ok') {
      throw const FormatException('No pedestrian route was returned.');
    }
    final routes = body['routes'] as List<dynamic>?;
    if (routes == null || routes.isEmpty) {
      throw const FormatException('Walking route response was empty.');
    }
    final route = routes.first as Map<String, dynamic>;
    final geometry = route['geometry'] as Map<String, dynamic>?;
    final coordinates = geometry?['coordinates'] as List<dynamic>?;
    if (coordinates == null || coordinates.length < 2) {
      throw const FormatException('Walking route geometry was missing.');
    }
    final points = coordinates.map((coordinate) {
      final values = coordinate as List<dynamic>;
      return LatLng(
        (values[1] as num).toDouble(),
        (values[0] as num).toDouble(),
      );
    }).toList();
    final instructions = <String>[];
    for (final legValue in route['legs'] as List<dynamic>? ?? const []) {
      final leg = legValue as Map<String, dynamic>;
      for (final stepValue in leg['steps'] as List<dynamic>? ?? const []) {
        final step = stepValue as Map<String, dynamic>;
        final maneuver = step['maneuver'] as Map<String, dynamic>?;
        final rawType = (maneuver?['type'] as String? ?? 'continue')
            .replaceAll('_', ' ')
            .trim();
        final type = rawType.isEmpty ? 'Continue' : rawType;
        final modifier = maneuver?['modifier'] as String?;
        final road = step['name'] as String? ?? '';
        final words = [
          type[0].toUpperCase() + type.substring(1),
          if (modifier != null && modifier.isNotEmpty) modifier,
          if (road.isNotEmpty) 'onto $road',
        ];
        final instruction = words.join(' ');
        if (instruction.isNotEmpty &&
            (instructions.isEmpty || instructions.last != instruction)) {
          instructions.add(instruction);
        }
      }
    }
    return WalkingRoute(
      points: points,
      duration: Duration(
        seconds: ((route['duration'] as num?)?.toDouble() ?? 0).round(),
      ),
      distanceMeters: (route['distance'] as num?)?.toDouble() ?? 0,
      instructions: instructions,
    );
  }
}
