import 'package:latlong2/latlong.dart';

/// A live vehicle position from a GTFS-Realtime feed.
class TransitVehicle {
  final String id;
  final String routeLabel;
  final String routeId;
  final String tripId;
  final int? currentStopSequence;
  final String? stopId;
  final double? speedMps;
  final String feedCategory;
  final LatLng position;
  final DateTime updatedAt;

  const TransitVehicle({
    required this.id,
    required this.routeLabel,
    this.routeId = '',
    this.tripId = '',
    this.currentStopSequence,
    this.stopId,
    this.speedMps,
    this.feedCategory = 'rapid-bus-kl',
    required this.position,
    required this.updatedAt,
  });
}
