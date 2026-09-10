import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

/// Official GTFS route geometry ready for map rendering.
class TransitShape {
  final String id;
  final String routeLabel;
  final String transportMode;
  final List<LatLng> points;
  final Color color;

  const TransitShape({
    required this.id,
    required this.routeLabel,
    required this.transportMode,
    required this.points,
    required this.color,
  });
}
