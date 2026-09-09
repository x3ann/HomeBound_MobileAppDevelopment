import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

enum LocationStatus { available, disabled, denied, deniedForever, unavailable }

class LocationResult {
  final LocationStatus status;
  final LatLng? position;
  final double? accuracyMeters;
  final DateTime? capturedAt;
  final bool isLastKnown;

  const LocationResult(
    this.status, [
    this.position,
    this.accuracyMeters,
    this.capturedAt,
    this.isLastKnown = false,
  ]);
}

/// Handles the permission, current-position, and continuous-position flows.
class LocationService {
  LocationService._();
  static final instance = LocationService._();

  Future<LocationResult> requestCurrentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const LocationResult(LocationStatus.disabled);
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        return const LocationResult(LocationStatus.denied);
      }
      if (permission == LocationPermission.deniedForever) {
        return const LocationResult(LocationStatus.deniedForever);
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      return LocationResult(
        LocationStatus.available,
        LatLng(position.latitude, position.longitude),
        position.accuracy,
        position.timestamp,
      );
    } catch (_) {
      try {
        final lastKnown = await Geolocator.getLastKnownPosition();
        if (lastKnown != null) {
          return LocationResult(
            LocationStatus.available,
            LatLng(lastKnown.latitude, lastKnown.longitude),
            lastKnown.accuracy,
            lastKnown.timestamp,
            true,
          );
        }
      } catch (_) {
        // The platform may also reject access to its last known position.
      }
      return const LocationResult(LocationStatus.unavailable);
    }
  }

  /// Emits the phone's current position and subsequent GPS updates.
  /// Consumers should cancel their subscription in dispose.
  Stream<LatLng> positionStream() async* {
    final initial = await requestCurrentLocation();
    if (initial.status != LocationStatus.available) return;
    yield initial.position!;
    await for (final position in Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 15,
      ),
    )) {
      yield LatLng(position.latitude, position.longitude);
    }
  }

  /// Watches location after permission has already been checked.
  Stream<LatLng> watchPosition() => Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 15,
        ),
      ).map((position) => LatLng(position.latitude, position.longitude));

  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();
}
