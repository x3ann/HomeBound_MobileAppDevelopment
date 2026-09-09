import 'package:latlong2/latlong.dart';

import '../shared/models/bus_arrival_estimate.dart';
import '../shared/models/stop.dart';
import '../shared/models/transit_vehicle.dart';
import '../shared/theme/app_theme.dart';
import 'gtfs_models.dart';
import 'gtfs_service.dart';

/// Produces clearly-labelled arrival estimates by combining current vehicle
/// positions with the matching official static trip and stop sequence.
class BusArrivalService {
  BusArrivalService._();
  static final instance = BusArrivalService._();

  final Map<String, Future<_BusSchedule>> _cache = {};

  /// Nearby official bus stops even when no vehicle can be matched to an ETA.
  Future<List<Stop>> nearbyStops({
    required LatLng userLocation,
    double radiusMeters = 2000,
    String category = 'rapid-bus-kl',
  }) async {
    final schedule = await _scheduleFor(category);
    const distance = Distance();
    final stops = schedule.stops.values
        .map((stop) {
          final position = LatLng(stop.lat, stop.lon);
          final meters = distance.as(LengthUnit.Meter, userLocation, position);
          final labels =
              schedule.routeLabelsByStop[stop.stopId] ?? const <String>[];
          final routeLabel = labels.take(3).join(' · ');
          return Stop(
            name: stop.name,
            platform:
                routeLabel.isEmpty ? 'Bus stop' : 'Bus stop · $routeLabel',
            position: position,
            timeToDeparture: Duration.zero,
            urgency: ServiceUrgency.onTime,
            gtfsStopId: stop.stopId,
            distanceMeters: meters,
            transportMode: 'Bus',
            routeLabel: routeLabel,
            hasDepartureData: false,
          );
        })
        .where(
            (stop) => (stop.distanceMeters ?? double.infinity) <= radiusMeters)
        .toList()
      ..sort((a, b) => a.distanceMeters!.compareTo(b.distanceMeters!));
    return stops.take(40).toList();
  }

  Future<List<BusArrivalEstimate>> estimateArrivals({
    required List<TransitVehicle> vehicles,
    required LatLng userLocation,
    String category = 'rapid-bus-kl',
  }) async {
    if (vehicles.isEmpty) return const [];
    final schedule = await _scheduleFor(category);
    const distance = Distance();
    final estimates = <BusArrivalEstimate>[];
    for (final vehicle in vehicles) {
      final trip = schedule.matchTrip(vehicle.tripId);
      if (trip == null) continue;
      final times = schedule.timesByTrip[trip.tripId];
      if (times == null || times.isEmpty) continue;
      final currentIndex = _currentIndex(vehicle, times, schedule.stops);
      if (currentIndex < 0) continue;
      final currentSeconds =
          GtfsService.gtfsTimeToSeconds(times[currentIndex].arrivalTime) ??
              GtfsService.gtfsTimeToSeconds(times[currentIndex].departureTime);
      if (currentSeconds == null) continue;
      for (var index = currentIndex; index < times.length; index++) {
        final time = times[index];
        final gtfsStop = schedule.stops[time.stopId];
        if (gtfsStop == null) continue;
        final stopPosition = LatLng(gtfsStop.lat, gtfsStop.lon);
        if (distance.as(LengthUnit.Kilometer, userLocation, stopPosition) > 3) {
          continue;
        }
        final targetSeconds = GtfsService.gtfsTimeToSeconds(time.arrivalTime) ??
            GtfsService.gtfsTimeToSeconds(time.departureTime);
        if (targetSeconds == null) continue;
        var etaSeconds = targetSeconds - currentSeconds;
        if (etaSeconds < 0) etaSeconds += 86400;
        if (index == currentIndex) {
          final meters =
              distance.as(LengthUnit.Meter, vehicle.position, stopPosition);
          etaSeconds = (meters / (vehicle.speedMps ?? 5.5)).round();
        }
        final route = schedule.routes[trip.routeId];
        final routeLabel = route == null
            ? (vehicle.routeId.isEmpty ? 'Rapid KL bus' : vehicle.routeId)
            : (route.shortName.isNotEmpty ? route.shortName : route.longName);
        estimates.add(BusArrivalEstimate(
          stop: Stop(
            name: gtfsStop.name,
            platform: 'Bus stop · $routeLabel',
            position: stopPosition,
            timeToDeparture: Duration(seconds: etaSeconds.clamp(0, 86400)),
            urgency: etaSeconds <= 300
                ? ServiceUrgency.critical
                : etaSeconds <= 1200
                    ? ServiceUrgency.closingSoon
                    : ServiceUrgency.onTime,
            gtfsStopId: gtfsStop.stopId,
            distanceMeters:
                distance.as(LengthUnit.Meter, userLocation, stopPosition),
            transportMode: 'Bus',
            routeLabel: routeLabel,
            hasDepartureData: true,
            isOperating: true,
          ),
          routeLabel: routeLabel,
          vehicleId: vehicle.id,
          eta: Duration(seconds: etaSeconds.clamp(0, 86400)),
        ));
      }
    }
    estimates.sort((a, b) => a.eta.compareTo(b.eta));
    final unique = <String, BusArrivalEstimate>{};
    for (final estimate in estimates) {
      unique.putIfAbsent(
          '${estimate.stop.gtfsStopId}|${estimate.routeLabel}', () => estimate);
    }
    return unique.values.take(8).toList();
  }

  int _currentIndex(TransitVehicle vehicle, List<GtfsStopTime> times,
      Map<String, GtfsStop> stops) {
    if (vehicle.currentStopSequence != null) {
      final index = times.indexWhere(
          (time) => time.stopSequence >= vehicle.currentStopSequence!);
      if (index >= 0) return index;
    }
    if (vehicle.stopId != null) {
      final index = times.indexWhere((time) => time.stopId == vehicle.stopId);
      if (index >= 0) return index;
    }
    const distance = Distance();
    var closestIndex = -1;
    var closestMeters = double.infinity;
    for (var index = 0; index < times.length; index++) {
      final stop = stops[times[index].stopId];
      if (stop == null) continue;
      final meters = distance.as(
          LengthUnit.Meter, vehicle.position, LatLng(stop.lat, stop.lon));
      if (meters < closestMeters) {
        closestMeters = meters;
        closestIndex = index;
      }
    }
    return closestMeters <= 2000 ? closestIndex : -1;
  }

  Future<_BusSchedule> _scheduleFor(String category) async {
    try {
      return await _cache.putIfAbsent(category, () => _load(category));
    } catch (_) {
      _cache.remove(category);
      rethrow;
    }
  }

  Future<_BusSchedule> _load(String category) async {
    final results = await Future.wait([
      GtfsService.fetchStops(category: category),
      GtfsService.fetchRoutes(category: category),
      GtfsService.fetchTrips(category: category),
      GtfsService.fetchStopTimes(category: category),
    ]);
    final stopTimes = results[3] as List<GtfsStopTime>;
    final byTrip = <String, List<GtfsStopTime>>{};
    for (final time in stopTimes) {
      byTrip.putIfAbsent(time.tripId, () => []).add(time);
    }
    for (final times in byTrip.values) {
      times.sort((a, b) => a.stopSequence.compareTo(b.stopSequence));
    }
    final trips = results[2] as List<GtfsTrip>;
    final routes = {
      for (final route in results[1] as List<GtfsRoute>) route.routeId: route
    };
    final routeByTrip = {
      for (final trip in trips) trip.tripId: routes[trip.routeId],
    };
    final labelsByStop = <String, Set<String>>{};
    for (final entry in byTrip.entries) {
      final route = routeByTrip[entry.key];
      if (route == null || route.displayName.isEmpty) continue;
      for (final time in entry.value) {
        labelsByStop
            .putIfAbsent(time.stopId, () => <String>{})
            .add(route.displayName);
      }
    }
    return _BusSchedule(
      stops: {
        for (final stop in results[0] as List<GtfsStop>) stop.stopId: stop
      },
      routes: routes,
      trips: trips,
      timesByTrip: byTrip,
      routeLabelsByStop: {
        for (final entry in labelsByStop.entries)
          entry.key: (entry.value.toList()..sort()),
      },
    );
  }
}

class _BusSchedule {
  final Map<String, GtfsStop> stops;
  final Map<String, GtfsRoute> routes;
  final List<GtfsTrip> trips;
  final Map<String, List<GtfsStopTime>> timesByTrip;
  final Map<String, List<String>> routeLabelsByStop;

  const _BusSchedule({
    required this.stops,
    required this.routes,
    required this.trips,
    required this.timesByTrip,
    required this.routeLabelsByStop,
  });

  GtfsTrip? matchTrip(String realtimeTripId) {
    if (realtimeTripId.isEmpty) return null;
    for (final trip in trips) {
      if (trip.tripId == realtimeTripId ||
          trip.tripId.endsWith('_$realtimeTripId') ||
          realtimeTripId.endsWith('_${trip.tripId}')) {
        return trip;
      }
    }
    return null;
  }
}
