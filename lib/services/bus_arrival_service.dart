import 'package:latlong2/latlong.dart';

import '../shared/models/bus_arrival_estimate.dart';
import '../shared/models/route_model.dart';
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
  final Map<String, DateTime> _cacheLoadedAt = {};
  final Map<String, String> _cacheServiceDate = {};

  void clearCache() {
    _cache.clear();
    _cacheLoadedAt.clear();
    _cacheServiceDate.clear();
  }

  Future<List<Stop>> searchScheduledStops(String query, {int limit = 8}) async {
    final needle = query.trim().toLowerCase();
    if (needle.length < 2) return const [];
    final groups = await Future.wait([
      scheduledStops(category: 'rapid-bus-kl').catchError((_) => <Stop>[]),
      scheduledStops(category: 'rapid-bus-mrtfeeder')
          .catchError((_) => <Stop>[]),
    ]);
    final unique = <String, Stop>{};
    for (final stop in groups.expand((group) => group)) {
      if (!stop.name.toLowerCase().contains(needle) &&
          !stop.routeLabel.toLowerCase().contains(needle)) {
        continue;
      }
      unique.putIfAbsent(
        '${stop.gtfsStopId}|${stop.routeLabel}',
        () => stop,
      );
      if (unique.length >= limit) break;
    }
    return unique.values.toList();
  }

  /// Complete scheduled stop directory for a bus feed. This is loaded only
  /// when the timetable or planner needs it; nearby screens continue to use
  /// the smaller radius-filtered result below.
  Future<List<Stop>> scheduledStops({
    String category = 'rapid-bus-kl',
  }) async {
    final schedule = await _scheduleFor(category);
    final nowSeconds = GtfsService.secondsIntoServiceDay(DateTime.now());
    return schedule.stops.values.expand((stop) {
      final byRoute = schedule.departuresByStopAndRoute[stop.stopId];
      if (byRoute == null || byRoute.isEmpty) {
        return [_scheduledStop(schedule, stop, nowSeconds)];
      }
      return byRoute.entries.map((entry) => _scheduledStop(
            schedule,
            stop,
            nowSeconds,
            labels: [entry.key],
            departures: entry.value,
          ));
    }).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<List<BusArrivalEstimate>> nearbyScheduledArrivals({
    required LatLng userLocation,
    double radiusMeters = 2000,
    String category = 'rapid-bus-kl',
  }) async {
    final schedule = await _scheduleFor(category);
    final nowSeconds = GtfsService.secondsIntoServiceDay(DateTime.now());
    const distance = Distance();
    final estimates = <BusArrivalEstimate>[];
    for (final stop in schedule.stops.values) {
      final position = LatLng(stop.lat, stop.lon);
      final meters = distance.as(LengthUnit.Meter, userLocation, position);
      if (meters > radiusMeters) continue;
      final byRoute = schedule.departuresByStopAndRoute[stop.stopId];
      if (byRoute == null) continue;
      for (final entry in byRoute.entries) {
        final departures = entry.value;
        if (departures.isEmpty ||
            nowSeconds < departures.first ||
            nowSeconds >= departures.last) {
          continue;
        }
        final next =
            departures.where((value) => value > nowSeconds).firstOrNull;
        if (next == null) continue;
        final eta = Duration(seconds: next - nowSeconds);
        estimates.add(BusArrivalEstimate(
          stop: Stop(
            name: stop.name,
            platform: 'Bus stop · ${entry.key}',
            position: position,
            timeToDeparture: eta,
            urgency: eta <= const Duration(minutes: 5)
                ? ServiceUrgency.critical
                : eta <= const Duration(minutes: 20)
                    ? ServiceUrgency.closingSoon
                    : ServiceUrgency.onTime,
            gtfsStopId: stop.stopId,
            distanceMeters: meters,
            transportMode: 'Bus',
            routeLabel: entry.key,
            lastService: GtfsService.formatSecondsAsClock(departures.last),
          ),
          routeLabel: entry.key,
          vehicleId: '',
          eta: eta,
        ));
      }
    }
    estimates.sort((a, b) {
      final byDistance = (a.stop.distanceMeters ?? double.infinity)
          .compareTo(b.stop.distanceMeters ?? double.infinity);
      return byDistance != 0 ? byDistance : a.eta.compareTo(b.eta);
    });
    return estimates;
  }

  /// Finds direct scheduled bus journeys whose boarding and alighting stops
  /// are within walking distance of the selected endpoints.
  Future<List<RouteOption>> planScheduledRoutes({
    required Stop origin,
    required Stop destination,
    String category = 'rapid-bus-kl',
    double maximumWalkMeters = 1500,
  }) async {
    final schedule = await _scheduleFor(category);
    const distance = Distance();
    final nowSeconds = GtfsService.secondsIntoServiceDay(DateTime.now());

    List<({GtfsStop stop, double meters})> nearest(LatLng point) {
      final matches = schedule.stops.values
          .map((stop) => (
                stop: stop,
                meters: distance.as(
                  LengthUnit.Meter,
                  point,
                  LatLng(stop.lat, stop.lon),
                ),
              ))
          .where((entry) => entry.meters <= maximumWalkMeters)
          .toList()
        ..sort((a, b) => a.meters.compareTo(b.meters));
      return matches.take(14).toList();
    }

    final origins = nearest(origin.position);
    final destinations = nearest(destination.position);
    if (origins.isEmpty || destinations.isEmpty) return const [];
    final originsById = {for (final entry in origins) entry.stop.stopId: entry};
    final destinationsById = {
      for (final entry in destinations) entry.stop.stopId: entry
    };
    final candidates = <RouteOption>[];

    for (final trip in schedule.trips) {
      if (!schedule.activeTripIds.contains(trip.tripId)) continue;
      final times = schedule.timesByTrip[trip.tripId];
      if (times == null || times.length < 2) continue;
      for (var fromIndex = 0; fromIndex < times.length - 1; fromIndex++) {
        final access = originsById[times[fromIndex].stopId];
        if (access == null) continue;
        final accessSeconds = (access.meters / 1.25).ceil();
        final departure = GtfsService.gtfsTimeToSeconds(
              times[fromIndex].departureTime,
            ) ??
            GtfsService.gtfsTimeToSeconds(times[fromIndex].arrivalTime);
        if (departure == null || departure < nowSeconds + accessSeconds) {
          continue;
        }
        for (var toIndex = fromIndex + 1; toIndex < times.length; toIndex++) {
          final egress = destinationsById[times[toIndex].stopId];
          if (egress == null) continue;
          final arrival = GtfsService.gtfsTimeToSeconds(
                times[toIndex].arrivalTime,
              ) ??
              GtfsService.gtfsTimeToSeconds(times[toIndex].departureTime);
          if (arrival == null || arrival <= departure) continue;
          final egressSeconds = (egress.meters / 1.25).ceil();
          final finalArrival = arrival + egressSeconds;
          final waitMinutes =
              ((departure - nowSeconds - accessSeconds) / 60).floor();
          final route = schedule.routes[trip.routeId];
          final routeLabel = route?.displayName.isNotEmpty == true
              ? route!.displayName
              : trip.routeId;
          final rideStops = toIndex - fromIndex;
          final totalMinutes =
              ((finalArrival - nowSeconds) / 60).ceil().clamp(1, 1440);
          candidates.add(RouteOption(
            departureTime: GtfsService.formatSecondsAsClock(departure),
            arrivalTime: GtfsService.formatSecondsAsClock(finalArrival),
            mode: 'Bus · $routeLabel',
            etaSummary:
                'Arrives ${GtfsService.formatSecondsAsClock(finalArrival)} · ${RouteOption.formatMinutes(totalMinutes)} total',
            status: ServiceUrgency.onTime,
            transferCount: 0,
            totalMinutes: totalMinutes,
            departureServiceSeconds: departure,
            arrivalServiceSeconds: finalArrival,
            steps: [
              'Leave now and walk ${(accessSeconds / 60).ceil()} min (${access.meters.round()} m) to ${access.stop.name}',
              if (waitMinutes > 0)
                'Wait about $waitMinutes min at ${access.stop.name}',
              'Board bus $routeLabel at ${GtfsService.formatSecondsAsClock(departure)}',
              'Stay on the bus for $rideStops stop${rideStops == 1 ? '' : 's'}',
              'Get off at ${egress.stop.name} around ${GtfsService.formatSecondsAsClock(arrival)}',
              'Walk ${(egressSeconds / 60).ceil()} min (${egress.meters.round()} m) to ${destination.name}',
              'Arrive at ${destination.name} around ${GtfsService.formatSecondsAsClock(finalArrival)}',
            ],
            checkpoints: [
              RouteCheckpoint(
                name: access.stop.name,
                position: LatLng(access.stop.lat, access.stop.lon),
                instruction: 'Board bus $routeLabel',
                serviceSeconds: departure,
              ),
              RouteCheckpoint(
                name: egress.stop.name,
                position: LatLng(egress.stop.lat, egress.stop.lon),
                instruction: 'Leave bus $routeLabel',
                serviceSeconds: arrival,
              ),
            ],
          ));
          break;
        }
      }
    }
    if (candidates.length < 3) {
      final inboundByTransfer = <String, List<_BusLeg>>{};
      for (final trip in schedule.trips) {
        if (!schedule.activeTripIds.contains(trip.tripId)) continue;
        final times = schedule.timesByTrip[trip.tripId];
        if (times == null) continue;
        for (var toIndex = 1; toIndex < times.length; toIndex++) {
          final egress = destinationsById[times[toIndex].stopId];
          if (egress == null) continue;
          final arrival = GtfsService.gtfsTimeToSeconds(
                times[toIndex].arrivalTime,
              ) ??
              GtfsService.gtfsTimeToSeconds(times[toIndex].departureTime);
          if (arrival == null) continue;
          for (var transferIndex = 0;
              transferIndex < toIndex;
              transferIndex++) {
            final departure = GtfsService.gtfsTimeToSeconds(
                  times[transferIndex].departureTime,
                ) ??
                GtfsService.gtfsTimeToSeconds(times[transferIndex].arrivalTime);
            if (departure == null || arrival <= departure) continue;
            inboundByTransfer
                .putIfAbsent(times[transferIndex].stopId, () => [])
                .add(_BusLeg(
                  tripId: trip.tripId,
                  routeLabel: _routeName(schedule, trip),
                  fromStop: schedule.stops[times[transferIndex].stopId]!,
                  toStop: egress.stop,
                  departure: departure,
                  arrival: arrival,
                  stopCount: toIndex - transferIndex,
                  endpointWalkMeters: egress.meters,
                ));
          }
        }
      }
      for (final legs in inboundByTransfer.values) {
        legs.sort((a, b) => a.arrival.compareTo(b.arrival));
      }
      outer:
      for (final trip in schedule.trips) {
        if (!schedule.activeTripIds.contains(trip.tripId)) continue;
        final times = schedule.timesByTrip[trip.tripId];
        if (times == null) continue;
        for (var fromIndex = 0; fromIndex < times.length - 1; fromIndex++) {
          final access = originsById[times[fromIndex].stopId];
          if (access == null) continue;
          final accessSeconds = (access.meters / 1.25).ceil();
          final departure = GtfsService.gtfsTimeToSeconds(
                times[fromIndex].departureTime,
              ) ??
              GtfsService.gtfsTimeToSeconds(times[fromIndex].arrivalTime);
          if (departure == null || departure < nowSeconds + accessSeconds) {
            continue;
          }
          for (var transferIndex = fromIndex + 1;
              transferIndex < times.length;
              transferIndex++) {
            final transferStop = schedule.stops[times[transferIndex].stopId];
            if (transferStop == null) continue;
            final transferArrival = GtfsService.gtfsTimeToSeconds(
                  times[transferIndex].arrivalTime,
                ) ??
                GtfsService.gtfsTimeToSeconds(
                    times[transferIndex].departureTime);
            if (transferArrival == null) continue;
            final inbound = inboundByTransfer[times[transferIndex].stopId]
                ?.where((leg) =>
                    leg.tripId != trip.tripId &&
                    leg.departure >= transferArrival + 180)
                .firstOrNull;
            if (inbound == null) continue;
            final egressSeconds = (inbound.endpointWalkMeters / 1.25).ceil();
            final finalArrival = inbound.arrival + egressSeconds;
            final totalMinutes =
                ((finalArrival - nowSeconds) / 60).ceil().clamp(1, 1440);
            final firstRoute = _routeName(schedule, trip);
            candidates.add(RouteOption(
              departureTime: GtfsService.formatSecondsAsClock(departure),
              arrivalTime: GtfsService.formatSecondsAsClock(finalArrival),
              mode: 'Bus · $firstRoute → ${inbound.routeLabel}',
              etaSummary:
                  'Arrives ${GtfsService.formatSecondsAsClock(finalArrival)} · ${RouteOption.formatMinutes(totalMinutes)} total',
              status: ServiceUrgency.onTime,
              transferCount: 1,
              totalMinutes: totalMinutes,
              departureServiceSeconds: departure,
              arrivalServiceSeconds: finalArrival,
              steps: [
                'Leave now and walk ${(accessSeconds / 60).ceil()} min (${access.meters.round()} m) to ${access.stop.name}',
                'Board bus $firstRoute at ${GtfsService.formatSecondsAsClock(departure)}',
                'Ride ${transferIndex - fromIndex} stops to ${transferStop.name}',
                'Change to bus ${inbound.routeLabel} at ${GtfsService.formatSecondsAsClock(inbound.departure)}',
                'Ride ${inbound.stopCount} stops to ${inbound.toStop.name}',
                'Get off around ${GtfsService.formatSecondsAsClock(inbound.arrival)}',
                'Walk ${(egressSeconds / 60).ceil()} min (${inbound.endpointWalkMeters.round()} m) to ${destination.name}',
                'Arrive at ${destination.name} around ${GtfsService.formatSecondsAsClock(finalArrival)}',
              ],
              checkpoints: [
                RouteCheckpoint(
                  name: access.stop.name,
                  position: LatLng(access.stop.lat, access.stop.lon),
                  instruction: 'Board bus $firstRoute',
                  serviceSeconds: departure,
                ),
                RouteCheckpoint(
                  name: transferStop.name,
                  position: LatLng(transferStop.lat, transferStop.lon),
                  instruction: 'Change to bus ${inbound.routeLabel}',
                  serviceSeconds: inbound.departure,
                ),
                RouteCheckpoint(
                  name: inbound.toStop.name,
                  position: LatLng(inbound.toStop.lat, inbound.toStop.lon),
                  instruction: 'Leave bus ${inbound.routeLabel}',
                  serviceSeconds: inbound.arrival,
                ),
              ],
            ));
            if (candidates.length >= 20) break outer;
          }
        }
      }
    }
    candidates.sort((a, b) => a.totalMinutes.compareTo(b.totalMinutes));
    final unique = <String, RouteOption>{};
    for (final candidate in candidates) {
      unique.putIfAbsent(
        '${candidate.mode}|${candidate.departureTime}|${candidate.arrivalTime}',
        () => candidate,
      );
    }
    return unique.values.take(3).toList();
  }

  /// Nearby official bus stops even when no vehicle can be matched to an ETA.
  Future<List<Stop>> nearbyStops({
    required LatLng userLocation,
    double radiusMeters = 2000,
    String category = 'rapid-bus-kl',
  }) async {
    final schedule = await _scheduleFor(category);
    const distance = Distance();
    final nowSeconds = GtfsService.secondsIntoServiceDay(DateTime.now());
    final stops = schedule.stops.values
        .map((stop) {
          final position = LatLng(stop.lat, stop.lon);
          final meters = distance.as(LengthUnit.Meter, userLocation, position);
          final labels =
              schedule.routeLabelsByStop[stop.stopId] ?? const <String>[];
          final routeLabel = labels.join(' · ');
          final departures =
              schedule.departuresByStop[stop.stopId] ?? const <int>[];
          final upcoming = departures.where((value) => value > nowSeconds);
          final next = upcoming.isEmpty ? null : upcoming.first;
          final operating = departures.isNotEmpty &&
              nowSeconds >= departures.first &&
              nowSeconds < departures.last;
          final remaining = next == null || !operating
              ? Duration.zero
              : Duration(seconds: next - nowSeconds);
          return Stop(
            name: stop.name,
            platform:
                routeLabel.isEmpty ? 'Bus stop' : 'Bus stop · $routeLabel',
            position: position,
            timeToDeparture: remaining,
            urgency: !operating || remaining <= const Duration(minutes: 5)
                ? ServiceUrgency.critical
                : remaining <= const Duration(minutes: 20)
                    ? ServiceUrgency.closingSoon
                    : ServiceUrgency.onTime,
            gtfsStopId: stop.stopId,
            distanceMeters: meters,
            transportMode: 'Bus',
            routeLabel: routeLabel,
            lastService: departures.isEmpty
                ? '—'
                : GtfsService.formatSecondsAsClock(departures.last),
            hasDepartureData: departures.isNotEmpty,
            isOperating: operating,
          );
        })
        .where(
            (stop) => (stop.distanceMeters ?? double.infinity) <= radiusMeters)
        .toList()
      ..sort((a, b) => a.distanceMeters!.compareTo(b.distanceMeters!));
    return stops.take(40).toList();
  }

  Stop _scheduledStop(
    _BusSchedule schedule,
    GtfsStop stop,
    int nowSeconds, {
    List<String>? labels,
    List<int>? departures,
  }) {
    final resolvedLabels =
        labels ?? schedule.routeLabelsByStop[stop.stopId] ?? const <String>[];
    final resolvedDepartures =
        departures ?? schedule.departuresByStop[stop.stopId] ?? const <int>[];
    final upcoming = resolvedDepartures.where((value) => value > nowSeconds);
    final next = upcoming.isEmpty ? null : upcoming.first;
    final operating = resolvedDepartures.isNotEmpty &&
        nowSeconds >= resolvedDepartures.first &&
        nowSeconds < resolvedDepartures.last;
    final remaining = next == null || !operating
        ? Duration.zero
        : Duration(seconds: next - nowSeconds);
    return Stop(
      name: stop.name,
      platform: resolvedLabels.isEmpty
          ? 'Bus stop'
          : 'Bus stop · ${resolvedLabels.join(' · ')}',
      position: LatLng(stop.lat, stop.lon),
      timeToDeparture: remaining,
      urgency: !operating || remaining <= const Duration(minutes: 5)
          ? ServiceUrgency.critical
          : remaining <= const Duration(minutes: 20)
              ? ServiceUrgency.closingSoon
              : ServiceUrgency.onTime,
      gtfsStopId: stop.stopId,
      transportMode: 'Bus',
      routeLabel: resolvedLabels.join(' · '),
      lastService: resolvedDepartures.isEmpty
          ? '—'
          : GtfsService.formatSecondsAsClock(resolvedDepartures.last),
      hasDepartureData: resolvedDepartures.isNotEmpty,
      isOperating: operating,
    );
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
      final rawCurrentSeconds =
          GtfsService.gtfsTimeToSeconds(times[currentIndex].arrivalTime) ??
              GtfsService.gtfsTimeToSeconds(times[currentIndex].departureTime);
      if (rawCurrentSeconds == null) continue;
      final nowSeconds = GtfsService.secondsIntoServiceDay(DateTime.now());
      final currentSeconds =
          _alignedServiceSeconds(rawCurrentSeconds, nowSeconds);
      if ((currentSeconds - nowSeconds).abs() > 2 * 3600) continue;
      final currentGtfsStop = schedule.stops[times[currentIndex].stopId];
      final approachSeconds = currentGtfsStop == null
          ? 0
          : (distance.as(
                    LengthUnit.Meter,
                    vehicle.position,
                    LatLng(currentGtfsStop.lat, currentGtfsStop.lon),
                  ) /
                  ((vehicle.speedMps ?? 5.5).clamp(3.0, 22.0)))
              .round()
              .clamp(0, 1800);
      for (var index = currentIndex; index < times.length; index++) {
        final time = times[index];
        final gtfsStop = schedule.stops[time.stopId];
        if (gtfsStop == null) continue;
        final stopPosition = LatLng(gtfsStop.lat, gtfsStop.lon);
        if (distance.as(LengthUnit.Kilometer, userLocation, stopPosition) > 3) {
          continue;
        }
        final rawTargetSeconds =
            GtfsService.gtfsTimeToSeconds(time.arrivalTime) ??
                GtfsService.gtfsTimeToSeconds(time.departureTime);
        if (rawTargetSeconds == null) continue;
        final targetSeconds =
            _alignedServiceSeconds(rawTargetSeconds, nowSeconds);
        var etaSeconds = targetSeconds - currentSeconds + approachSeconds;
        if (etaSeconds < 0 || etaSeconds > 2 * 3600) continue;
        if (index == currentIndex) {
          final meters =
              distance.as(LengthUnit.Meter, vehicle.position, stopPosition);
          etaSeconds =
              (meters / ((vehicle.speedMps ?? 5.5).clamp(3.0, 22.0))).round();
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
            isLiveEstimate: true,
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

  int _alignedServiceSeconds(int seconds, int nowSeconds) {
    if (nowSeconds >= 86400 && seconds < 4 * 3600) return seconds + 86400;
    return seconds;
  }

  String _routeName(_BusSchedule schedule, GtfsTrip trip) {
    final route = schedule.routes[trip.routeId];
    return route?.displayName.isNotEmpty == true
        ? route!.displayName
        : trip.routeId;
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
    final now = DateTime.now();
    final serviceDate = GtfsService.dateStamp(GtfsService.serviceDateFor(now));
    final loadedAt = _cacheLoadedAt[category];
    final stale = loadedAt == null ||
        now.difference(loadedAt) > const Duration(minutes: 30) ||
        _cacheServiceDate[category] != serviceDate;
    if (stale) {
      _cache.remove(category);
      _cacheLoadedAt.remove(category);
      _cacheServiceDate.remove(category);
    }
    try {
      final schedule =
          await _cache.putIfAbsent(category, () => _load(category));
      _cacheLoadedAt.putIfAbsent(category, () => now);
      _cacheServiceDate.putIfAbsent(category, () => serviceDate);
      return schedule;
    } catch (_) {
      _cache.remove(category);
      _cacheLoadedAt.remove(category);
      _cacheServiceDate.remove(category);
      rethrow;
    }
  }

  Future<_BusSchedule> _load(String category) async {
    final results = await Future.wait([
      GtfsService.fetchStops(category: category),
      GtfsService.fetchRoutes(category: category),
      GtfsService.fetchTrips(category: category),
      GtfsService.fetchStopTimes(category: category),
      GtfsService.fetchCalendar(category: category),
      GtfsService.fetchCalendarDates(category: category),
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
    final activeTripIds = GtfsService.activeTripIds(
      trips: trips,
      calendar: results[4] as List<GtfsCalendarService>,
      calendarDates: results[5] as List<GtfsCalendarDate>,
      serviceDate: GtfsService.serviceDateFor(DateTime.now()),
    );
    final routes = {
      for (final route in results[1] as List<GtfsRoute>) route.routeId: route
    };
    final routeByTrip = {
      for (final trip in trips) trip.tripId: routes[trip.routeId],
    };
    final labelsByStop = <String, Set<String>>{};
    final departuresByStop = <String, List<int>>{};
    final departuresByStopAndRoute = <String, Map<String, List<int>>>{};
    for (final entry in byTrip.entries) {
      final route = routeByTrip[entry.key];
      if (route == null || route.displayName.isEmpty) continue;
      for (final time in entry.value) {
        labelsByStop
            .putIfAbsent(time.stopId, () => <String>{})
            .add(route.displayName);
        if (activeTripIds.contains(entry.key)) {
          final seconds = GtfsService.gtfsTimeToSeconds(time.departureTime) ??
              GtfsService.gtfsTimeToSeconds(time.arrivalTime);
          if (seconds != null) {
            departuresByStop.putIfAbsent(time.stopId, () => []).add(seconds);
            departuresByStopAndRoute
                .putIfAbsent(time.stopId, () => {})
                .putIfAbsent(route.displayName, () => [])
                .add(seconds);
          }
        }
      }
    }
    for (final departures in departuresByStop.values) {
      departures.sort();
    }
    for (final byRoute in departuresByStopAndRoute.values) {
      for (final departures in byRoute.values) {
        departures.sort();
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
      departuresByStop: departuresByStop,
      departuresByStopAndRoute: departuresByStopAndRoute,
      activeTripIds: activeTripIds,
    );
  }
}

class _BusSchedule {
  final Map<String, GtfsStop> stops;
  final Map<String, GtfsRoute> routes;
  final List<GtfsTrip> trips;
  final Map<String, List<GtfsStopTime>> timesByTrip;
  final Map<String, List<String>> routeLabelsByStop;
  final Map<String, List<int>> departuresByStop;
  final Map<String, Map<String, List<int>>> departuresByStopAndRoute;
  final Set<String> activeTripIds;

  const _BusSchedule({
    required this.stops,
    required this.routes,
    required this.trips,
    required this.timesByTrip,
    required this.routeLabelsByStop,
    required this.departuresByStop,
    required this.departuresByStopAndRoute,
    required this.activeTripIds,
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

class _BusLeg {
  final String tripId;
  final String routeLabel;
  final GtfsStop fromStop;
  final GtfsStop toStop;
  final int departure;
  final int arrival;
  final int stopCount;
  final double endpointWalkMeters;

  const _BusLeg({
    required this.tripId,
    required this.routeLabel,
    required this.fromStop,
    required this.toStop,
    required this.departure,
    required this.arrival,
    required this.stopCount,
    required this.endpointWalkMeters,
  });
}
