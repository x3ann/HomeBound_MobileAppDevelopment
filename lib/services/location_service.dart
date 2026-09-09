import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

enum LocationStatus { available, disabled, denied, deniedForever, unavailable }

class LocationResult {
  final LocationStatus status;
  final LatLng? position;

  const LocationResult(this.status, [this.position]);
}

/// Requests location only after an explicit user action, so the app never
/// surprises people with a permission dialog on launch.
class LocationService {
  LocationService._();
  static final instance = LocationService._();

  Future<LocationResult> requestCurrentLocation() async {
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
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      return LocationResult(LocationStatus.available,
          LatLng(position.latitude, position.longitude));
    } catch (_) {
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) {
        return LocationResult(
          LocationStatus.available,
          LatLng(lastKnown.latitude, lastKnown.longitude),
        );
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
}
