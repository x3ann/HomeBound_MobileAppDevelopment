import 'package:flutter_test/flutter_test.dart';
import 'package:homebound/services/walking_route_service.dart';

void main() {
  test('parses road-following GeoJSON route geometry and duration', () {
    final route = WalkingRouteService.parseResponse({
      'code': 'Ok',
      'routes': [
        {
          'distance': 780.0,
          'duration': 600.0,
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              [101.6, 3.1],
              [101.61, 3.11],
            ],
          },
          'legs': [
            {
              'steps': [
                {
                  'name': 'Jalan Example',
                  'maneuver': {'type': 'turn', 'modifier': 'left'},
                }
              ],
            }
          ],
        }
      ],
    });

    expect(route.points, hasLength(2));
    expect(route.points.first.latitude, 3.1);
    expect(route.duration, const Duration(minutes: 10));
    expect(route.distanceMeters, 780);
    expect(route.instructions.first, contains('Jalan Example'));
  });
}
