import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'route_model.dart';
import 'stop.dart';

class PlannedJourney {
  final Stop origin;
  final Stop destination;
  final RouteOption route;

  const PlannedJourney({
    required this.origin,
    required this.destination,
    required this.route,
  });

  double progressAt(int serviceSeconds) {
    return route.progressAt(serviceSeconds);
  }

  int activeStepAt(int serviceSeconds) {
    if (route.steps.isEmpty) return 0;
    final progress = progressAt(serviceSeconds);
    return (progress * route.steps.length)
        .floor()
        .clamp(0, route.steps.length - 1);
  }

  int activeCheckpointAt(int serviceSeconds) =>
      route.activeCheckpointAt(serviceSeconds);

  /// Locates the phone along the simplified journey path. A null result means
  /// the position is too far from that path to safely change progress.
  double? progressForPosition(
    LatLng position, {
    double maximumDistanceMeters = 500,
  }) {
    final points = [
      origin.position,
      ...route.checkpoints.map((checkpoint) => checkpoint.position),
      destination.position,
    ];
    if (points.length < 2) return null;

    final referenceLatitude = position.latitude * math.pi / 180;
    ({double x, double y}) project(LatLng point) => (
          x: point.longitude * 111320 * math.cos(referenceLatitude),
          y: point.latitude * 110540,
        );

    final projectedPosition = project(position);
    final projectedPoints = points.map(project).toList();
    final lengths = <double>[];
    var totalLength = 0.0;
    for (var index = 0; index + 1 < projectedPoints.length; index++) {
      final dx = projectedPoints[index + 1].x - projectedPoints[index].x;
      final dy = projectedPoints[index + 1].y - projectedPoints[index].y;
      final length = math.sqrt(dx * dx + dy * dy);
      lengths.add(length);
      totalLength += length;
    }
    if (totalLength <= 0) return null;

    var closestDistance = double.infinity;
    var closestProgress = 0.0;
    var distanceBeforeSegment = 0.0;
    for (var index = 0; index < lengths.length; index++) {
      final start = projectedPoints[index];
      final end = projectedPoints[index + 1];
      final dx = end.x - start.x;
      final dy = end.y - start.y;
      final squaredLength = dx * dx + dy * dy;
      if (squaredLength <= 0) continue;
      final rawProjection = ((projectedPosition.x - start.x) * dx +
              (projectedPosition.y - start.y) * dy) /
          squaredLength;
      final projection = rawProjection.clamp(0.0, 1.0);
      final nearestX = start.x + dx * projection;
      final nearestY = start.y + dy * projection;
      final distance = math.sqrt(
        math.pow(projectedPosition.x - nearestX, 2) +
            math.pow(projectedPosition.y - nearestY, 2),
      );
      if (distance < closestDistance) {
        closestDistance = distance;
        closestProgress =
            (distanceBeforeSegment + lengths[index] * projection) / totalLength;
      }
      distanceBeforeSegment += lengths[index];
    }
    if (closestDistance > maximumDistanceMeters) return null;
    return closestProgress.clamp(0.0, 1.0);
  }

  int activeStepAtProgress(double progress) {
    if (route.steps.isEmpty) return 0;
    return (progress * route.steps.length)
        .floor()
        .clamp(0, route.steps.length - 1);
  }

  int activeCheckpointAtProgress(double progress) {
    final checkpoints = route.checkpoints;
    if (checkpoints.isEmpty) return 0;
    return (progress * (checkpoints.length + 1))
        .floor()
        .clamp(0, checkpoints.length - 1);
  }
}
