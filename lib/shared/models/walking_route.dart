import 'package:latlong2/latlong.dart';

class WalkingRoute {
  final List<LatLng> points;
  final Duration duration;
  final double distanceMeters;
  final List<String> instructions;

  const WalkingRoute({
    required this.points,
    required this.duration,
    required this.distanceMeters,
    this.instructions = const [],
  });
}
