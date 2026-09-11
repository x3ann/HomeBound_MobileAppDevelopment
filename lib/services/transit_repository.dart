import 'dart:math' as math;

import 'package:flutter/material.dart' show Color;
import 'package:latlong2/latlong.dart';
import '../shared/models/stop.dart';
import '../shared/models/route_model.dart';
import '../shared/models/transit_shape.dart';
import '../shared/theme/app_theme.dart';
import 'gtfs_models.dart';
import 'gtfs_service.dart';
import 'experimental_rail_service.dart';
import 'bus_arrival_service.dart';

/// Where the currently-displayed stop data came from. Surfaced in the UI
/// (small badge) so it's honest about whether a session is live or offline.
enum TransitDataSource { official, cached, unavailable }

class TransitLookupResult {
  final List<Stop> stops;
  final TransitDataSource source;
  const TransitLookupResult(this.stops, this.source);
}

/// Single source of truth for "what stops should the app show right now".
///
/// Tries the real GTFS Static API (api.data.gov.my, no key required) first.
/// On success, station names and coordinates come directly from the feed.
/// Stop times, repeating frequency windows, trips, calendars, and service-day
/// exceptions are combined to calculate today's next departure and last
/// service for every station.
///
/// On a refresh failure, the last successfully loaded in-memory schedule is
/// retained. If no schedule has loaded yet, the UI receives an empty result
/// and presents an explicit retry state instead of fabricated transit data.
class TransitRepository {
  TransitRepository._();
  static final TransitRepository instance = TransitRepository._();

  List<Stop>? _cachedStops;
  List<Stop>? _stationDirectory;
  TransitDataSource _lastSource = TransitDataSource.unavailable;

  List<GtfsStopTime>? _stopTimes;
  List<GtfsTrip>? _trips;
  List<GtfsCalendarService>? _calendar;
  List<GtfsCalendarDate>? _calendarDates;
  List<GtfsRoute>? _routes;
  List<GtfsFrequency>? _frequencies;
  Set<String>? _activeTripIds;
  String? _activeDate;

  TransitDataSource get lastSource => _lastSource;

  /// Complete official rail-station directory used by selectors and search.
  Future<List<Stop>> getStationDirectory() async {
    if (_cachedStops == null) await getNearbyStops();
    await _ensureStationDirectory();
    return List<Stop>.unmodifiable(_cachedStops ?? _stationDirectory!);
  }

  /// Timetable rows are split by line so a shared interchange never displays
  /// another line's later closing time as its own last service.
  Future<List<Stop>> getRailTimetableEntries() async {
    await _ensureStationDirectory();
    await _ensureScheduleLoaded();
    final directory = _stationDirectory ?? const <Stop>[];
    final stopById = {
      for (final stop in directory)
        if (stop.gtfsStopId != null) stop.gtfsStopId!: stop,
    };
    final schedules = _directionSchedules();
    final nowSeconds = GtfsService.secondsIntoServiceDay(DateTime.now());
    final result = <Stop>[];
    for (final entry in schedules.entries) {
      final stop = stopById[entry.key];
      if (stop == null) continue;
      for (final schedule in entry.value.values) {
        final option = _directionOption(stop, schedule, nowSeconds);
        result.add(stop.copyWith(
          directionOptions: [option],
          selectedDirectionKey: option.key,
        ).withDirection(option.key));
      }
    }
    result.sort((a, b) {
      final byMode = a.transportMode.compareTo(b.transportMode);
      if (byMode != 0) return byMode;
      final byLine = a.routeLabel.compareTo(b.routeLabel);
      return byLine != 0 ? byLine : a.name.compareTo(b.name);
    });
    return result;
  }

  Future<TransitLookupResult> getNearbyStops(
      {bool forceRefresh = false}) async {
    if (_cachedStops != null && !forceRefresh) {
      return TransitLookupResult(_cachedStops!, TransitDataSource.cached);
    }

    if (forceRefresh) {
      GtfsService.clearCache();
      _stopTimes = null;
      _trips = null;
      _calendar = null;
      _calendarDates = null;
      _routes = null;
      _frequencies = null;
      _activeTripIds = null;
      _activeDate = null;
    }

    try {
      final gtfsStops = await GtfsService.fetchStops(category: 'rapid-rail-kl');
      var merged = gtfsStops
          .map((stop) => Stop(
              name: stop.name,
              platform: 'Rapid Rail station',
              position: LatLng(stop.lat, stop.lon),
              timeToDeparture: Duration.zero,
              urgency: ServiceUrgency.onTime,
              gtfsStopId: stop.stopId))
          .toList();
      // Direction labels need station names while the first schedule is built.
      _stationDirectory = merged;
      merged = await _withRealSchedule(merged);
      _cachedStops = merged;
      _stationDirectory = merged;
      _lastSource = TransitDataSource.official;
      return TransitLookupResult(merged, TransitDataSource.official);
    } catch (_) {
      if (_cachedStops != null) {
        _lastSource = TransitDataSource.cached;
        return TransitLookupResult(_cachedStops!, TransitDataSource.cached);
      }
      _lastSource = TransitDataSource.unavailable;
      return const TransitLookupResult([], TransitDataSource.unavailable);
    }
  }

  /// Recalculates countdowns from the cached official timetable. This handles
  /// app sessions crossing midnight without downloading the feed again.
  Future<TransitLookupResult> recalculateStops() async {
    if (_cachedStops == null) return getNearbyStops();
    try {
      final updated = await _withRealSchedule(_cachedStops!);
      _cachedStops = updated;
      _stationDirectory = updated;
      return TransitLookupResult(updated, TransitDataSource.cached);
    } catch (_) {
      return TransitLookupResult(_cachedStops!, TransitDataSource.cached);
    }
  }

  /// Orders the available stop list by walking distance from a device location.
  /// The distance is calculated locally, so this still works with cached data.
  List<Stop> sortByDistance(List<Stop> stops, LatLng userLocation) {
    const distance = Distance();
    final ordered = stops
        .map((stop) => stop.copyWith(
              distanceMeters:
                  distance.as(LengthUnit.Meter, userLocation, stop.position),
            ))
        .toList();
    ordered.sort((a, b) => a.distanceMeters!.compareTo(b.distanceMeters!));
    return ordered;
  }

  Future<Stop> withExperimentalEstimate(Stop stop) async {
    final id = stop.gtfsStopId;
    if (id == null) return stop;
    final estimate = await ExperimentalRailService.instance.estimateForStop(id);
    return estimate == null
        ? stop
        : stop.copyWith(liveRailEstimate: estimate.text);
  }

  Future<List<TransitShape>> getRailShapes() =>
      getTransitShapes(category: 'rapid-rail-kl');

  Future<List<TransitShape>> getTransitShapes(
      {required String category}) async {
    final results = await Future.wait([
      GtfsService.fetchShapes(category: category),
      GtfsService.fetchTrips(category: category),
      GtfsService.fetchRoutes(category: category),
      GtfsService.fetchStops(category: category),
      GtfsService.fetchStopTimes(category: category),
    ]);
    final shapePoints = results[0] as List<GtfsShapePoint>;
    final trips = results[1] as List<GtfsTrip>;
    final routes = results[2] as List<GtfsRoute>;
    final stops = results[3] as List<GtfsStop>;
    final stopTimes = results[4] as List<GtfsStopTime>;
    final routeById = {for (final route in routes) route.routeId: route};
    final routeIdsByShape = <String, Set<String>>{};
    for (final trip in trips) {
      if (trip.shapeId.isNotEmpty) {
        routeIdsByShape
            .putIfAbsent(trip.shapeId, () => <String>{})
            .add(trip.routeId);
      }
    }
    final grouped = <String, List<GtfsShapePoint>>{};
    for (final point in shapePoints) {
      if (routeIdsByShape.containsKey(point.shapeId)) {
        grouped.putIfAbsent(point.shapeId, () => []).add(point);
      }
    }
    const colors = [
      Color(0xFFE53935),
      Color(0xFF1E88E5),
      Color(0xFF43A047),
      Color(0xFFFDD835),
      Color(0xFF8E24AA),
      Color(0xFF00ACC1),
      Color(0xFFFB8C00),
      Color(0xFF6D4C41),
    ];
    final labels = routes.map((route) => route.displayName).toSet().toList()
      ..sort();
    final colorByRoute = {
      for (var i = 0; i < labels.length; i++)
        labels[i]: colors[i % colors.length]
    };
    final shapes = <TransitShape>[];
    final coveredRouteIds = <String>{};
    for (final entry in grouped.entries) {
      final ordered = entry.value
        ..sort((a, b) => a.sequence.compareTo(b.sequence));
      for (final routeId in routeIdsByShape[entry.key] ?? const <String>{}) {
        final route = routeById[routeId];
        if (route == null) continue;
        coveredRouteIds.add(routeId);
        shapes.add(TransitShape(
          id: '${entry.key}|$routeId',
          routeLabel: route.displayName,
          transportMode: route.modeLabel,
          points: ordered.map((point) => LatLng(point.lat, point.lon)).toList(),
          color: colorByRoute[route.displayName] ?? colors.first,
        ));
      }
    }

    // Some feeds omit shapes for individual lines. Build a conservative
    // fallback from the longest published stop sequence for that route.
    final stopById = {for (final stop in stops) stop.stopId: stop};
    final timesByTrip = <String, List<GtfsStopTime>>{};
    for (final time in stopTimes) {
      timesByTrip.putIfAbsent(time.tripId, () => []).add(time);
    }
    for (final route
        in routes.where((route) => !coveredRouteIds.contains(route.routeId))) {
      final candidates = trips
          .where((trip) => trip.routeId == route.routeId)
          .map((trip) => MapEntry(
                trip,
                timesByTrip[trip.tripId] ?? const <GtfsStopTime>[],
              ))
          .where((entry) => entry.value.length > 1)
          .toList()
        ..sort((a, b) => b.value.length.compareTo(a.value.length));
      if (candidates.isEmpty) continue;
      final ordered = [...candidates.first.value]
        ..sort((a, b) => a.stopSequence.compareTo(b.stopSequence));
      final points = ordered
          .map((time) => stopById[time.stopId])
          .whereType<GtfsStop>()
          .map((stop) => LatLng(stop.lat, stop.lon))
          .toList();
      if (points.length < 2) continue;
      shapes.add(TransitShape(
        id: 'stops|${route.routeId}',
        routeLabel: route.displayName,
        transportMode: route.modeLabel,
        points: points,
        color: colorByRoute[route.displayName] ?? colors.first,
      ));
    }
    return shapes;
  }

  /// Official station directory for origin and destination autocomplete.
  Future<List<Stop>> searchStops(String query) async {
    if (_cachedStops == null) await getNearbyStops();
    await _ensureStationDirectory();
    final needle = normalizeSearchText(query);
    if (needle.isEmpty) return const [];
    final matches = _stationDirectory!
        .where((stop) =>
            normalizeSearchText(stop.name).contains(needle) ||
            normalizeSearchText(stop.routeLabel).contains(needle))
        .toList();
    matches.sort((a, b) {
      final aName = normalizeSearchText(a.name);
      final bName = normalizeSearchText(b.name);
      final aRank = aName == needle ? 0 : (aName.startsWith(needle) ? 1 : 2);
      final bRank = bName == needle ? 0 : (bName.startsWith(needle) ? 1 : 2);
      return aRank != bRank ? aRank.compareTo(bRank) : aName.compareTo(bName);
    });
    return matches.take(6).toList();
  }

  static String normalizeSearchText(String value) => value
      .toLowerCase()
      .replaceAll(
          RegExp(r'\b(mrt|lrt|monorail|brt|rail|station|stesen)\b'), ' ')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Plans directly from selected suggestions so duplicate station names and
  /// opposite-direction platforms are handled as one interchange.
  Future<List<RouteOption>> planRouteBetweenStops(
    Stop origin,
    Stop destination,
  ) async {
    final busFuture = _planBusAlternatives(
      origin,
      destination,
      maximumWalkMeters: 1500,
    );
    final railOptions = <RouteOption>[];
    try {
      await _ensureStationDirectory();
      await _ensureScheduleLoaded();
      final directory = _stationDirectory ?? const <Stop>[];
      final originMatches = _stationMatches(origin, directory);
      final destinationMatches = _stationMatches(destination, directory);
      if (originMatches.isNotEmpty && destinationMatches.isNotEmpty) {
        const distance = Distance();
        final nowSeconds = GtfsService.secondsIntoServiceDay(DateTime.now());
        final destinationById = {
          for (final stop in destinationMatches)
            if (stop.gtfsStopId != null) stop.gtfsStopId!: stop,
        };
        final destinationWalkSeconds = {
          for (final entry in destinationById.entries)
            entry.key: destination.gtfsStopId == null
                ? (distance.as(LengthUnit.Meter, entry.value.position,
                            destination.position) /
                        1.25)
                    .round()
                : 0,
        };
        // Each possible boarding station has a different access walk. Search
        // it independently, then rank all results by the complete door-to-door
        // duration. Destination choice includes the walk from that exact stop.
        for (final originStation in originMatches) {
          final originId = originStation.gtfsStopId;
          if (originId == null) continue;
          final accessMeters = origin.gtfsStopId == null
              ? distance.as(
                  LengthUnit.Meter, origin.position, originStation.position)
              : 0.0;
          final accessSeconds = (accessMeters / 1.25).round();
          final routes = _scanNetworkRoutes(
            {originId},
            destinationById.keys.toSet(),
            nowSeconds + accessSeconds,
            destinationWalkSeconds: destinationWalkSeconds,
          );
          railOptions.addAll(routes.map((route) {
            final destinationStation =
                destinationById[route.destinationStopId] ??
                    destinationMatches.first;
            final egressMeters = destination.gtfsStopId == null
                ? distance.as(LengthUnit.Meter, destinationStation.position,
                    destination.position)
                : 0.0;
            final egressSeconds = (egressMeters / 1.25).round();
            final finalArrival = route.arrivalServiceSeconds + egressSeconds;
            final totalMinutes =
                math.max(1, ((finalArrival - nowSeconds) / 60).ceil());
            return RouteOption(
              departureTime: route.departureTime,
              mode: route.mode,
              etaSummary:
                  'Arrives ${GtfsService.formatSecondsAsClock(finalArrival)} · ${RouteOption.formatMinutes(totalMinutes)} total',
              status: route.status,
              steps: [
                if (accessSeconds > 0)
                  'Leave now and walk ${(accessSeconds / 60).ceil()} min (${accessMeters.round()} m) to ${originStation.name}',
                ...route.steps,
                if (egressSeconds > 0)
                  'Exit the station and walk ${(egressSeconds / 60).ceil()} min (${egressMeters.round()} m) to ${destination.name}',
                'Arrive at ${destination.name} around ${GtfsService.formatSecondsAsClock(finalArrival)}',
              ],
              checkpoints: route.checkpoints,
              transferCount: route.transferCount,
              arrivalTime: GtfsService.formatSecondsAsClock(finalArrival),
              totalMinutes: totalMinutes,
              isRecommended: route.isRecommended,
              departureServiceSeconds: route.departureServiceSeconds,
              arrivalServiceSeconds: finalArrival,
              destinationStopId: route.destinationStopId,
            );
          }));
        }
      }
    } catch (_) {
      // Bus planning remains useful when the rail schedule is unavailable.
    }
    var busOptions = await busFuture;
    // A nearby bus route is useful as a variation even when it requires a
    // longer access walk. Keep the normal result comfortable, then widen the
    // verified official-feed search only when it found no bus at all.
    if (busOptions.isEmpty) {
      busOptions = await _planBusAlternatives(
        origin,
        destination,
        maximumWalkMeters: 3000,
      );
    }
    return _rankMultimodal([
      ...railOptions,
      ...busOptions,
    ]);
  }

  Future<List<RouteOption>> _planBusAlternatives(
    Stop origin,
    Stop destination, {
    required double maximumWalkMeters,
  }) async {
    final groups = await Future.wait(
      ['rapid-bus-kl', 'rapid-bus-mrtfeeder'].map(
        (category) => BusArrivalService.instance
            .planScheduledRoutes(
              origin: origin,
              destination: destination,
              category: category,
              maximumWalkMeters: maximumWalkMeters,
            )
            .catchError((_) => <RouteOption>[]),
      ),
    );
    return groups.expand((options) => options).toList();
  }

  /// Keeps the fastest result first and deliberately surfaces the best
  /// different transport mode as the next choice when one exists.
  List<RouteOption> _rankMultimodal(Iterable<RouteOption> options) {
    final ranked = options.toList()
      ..sort((a, b) {
        final byDuration = a.totalMinutes.compareTo(b.totalMinutes);
        if (byDuration != 0) return byDuration;
        return a.transferCount.compareTo(b.transferCount);
      });
    final distinct = <String, RouteOption>{};
    for (final option in ranked) {
      distinct.putIfAbsent(option.mode.trim().toLowerCase(), () => option);
    }
    final alternatives = distinct.values.toList();
    if (alternatives.isEmpty) return const [];
    final selected = <RouteOption>[alternatives.first];
    final firstIsBus = alternatives.first.mode.toLowerCase().contains('bus');
    for (final option in alternatives.skip(1)) {
      final isBus = option.mode.toLowerCase().contains('bus');
      if (isBus != firstIsBus) {
        selected.add(option);
        break;
      }
    }
    for (final option in alternatives.skip(1)) {
      if (selected.contains(option)) continue;
      selected.add(option);
      if (selected.length == 4) break;
    }
    return selected
        .asMap()
        .entries
        .map((entry) => entry.value.copyWith(isRecommended: entry.key == 0))
        .toList();
  }

  List<Stop> _stationMatches(Stop selected, List<Stop> directory) {
    if (selected.gtfsStopId == null) {
      return sortByDistance(directory, selected.position).take(4).toList();
    }
    final normalized = normalizeSearchText(selected.name);
    final matches = directory
        .where((stop) => normalizeSearchText(stop.name) == normalized)
        .toList();
    if (matches.isNotEmpty) return matches;
    return directory
        .where((stop) => stop.gtfsStopId == selected.gtfsStopId)
        .toList();
  }

  /// Finds scheduled journeys with walking connections and up to three
  /// interchanges. Several departure offsets produce useful alternatives.
  Future<List<RouteOption>> planRoute(
      String originName, String destinationName) async {
    await _ensureStationDirectory();
    final coordinateMatch = RegExp(
      r'\((-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\)',
    ).firstMatch(originName);
    final origins = coordinateMatch == null
        ? await searchStops(originName)
        : sortByDistance(
            _stationDirectory!,
            LatLng(
              double.parse(coordinateMatch.group(1)!),
              double.parse(coordinateMatch.group(2)!),
            ),
          ).take(4).toList();
    final destinations = await searchStops(destinationName);
    if (origins.isEmpty || destinations.isEmpty) return const [];
    await _ensureScheduleLoaded();
    final nowSeconds = GtfsService.secondsIntoServiceDay(DateTime.now());
    final advanced = _scanNetworkRoutes(
      coordinateMatch == null
          ? _resolvedStopIds(origins, originName)
          : origins.map((stop) => stop.gtfsStopId).whereType<String>().toSet(),
      _resolvedStopIds(destinations, destinationName),
      nowSeconds,
    );
    if (advanced.isNotEmpty) return advanced;
    return _planLegacyRoute(originName, destinationName);
  }

  Set<String> _resolvedStopIds(List<Stop> matches, String query) {
    final needle = query.trim().toLowerCase();
    final exact = matches
        .where((stop) => stop.name.trim().toLowerCase() == needle)
        .toList();
    final selected = exact.isNotEmpty ? exact : matches.take(1);
    return selected.map((stop) => stop.gtfsStopId).whereType<String>().toSet();
  }

  Future<List<RouteOption>> _planLegacyRoute(
      String originName, String destinationName) async {
    await _ensureStationDirectory();
    final coordinateMatch = RegExp(
      r'\((-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\)',
    ).firstMatch(originName);
    final origins = coordinateMatch == null
        ? await searchStops(originName)
        : sortByDistance(
            _stationDirectory!,
            LatLng(
              double.parse(coordinateMatch.group(1)!),
              double.parse(coordinateMatch.group(2)!),
            ),
          ).take(4).toList();
    final destinations = await searchStops(destinationName);
    if (origins.isEmpty || destinations.isEmpty) return const [];
    await _ensureScheduleLoaded();
    final originIds = coordinateMatch == null
        ? _resolvedStopIds(origins, originName)
        : origins.map((stop) => stop.gtfsStopId).whereType<String>().toSet();
    final destinationIds = _resolvedStopIds(destinations, destinationName);
    if (originIds.isEmpty || destinationIds.isEmpty) return const [];
    final now = DateTime.now();
    final nowSeconds = GtfsService.secondsIntoServiceDay(now);
    final byTrip = _tripInstances();
    final routeNames = {
      for (final route in _routes!) route.routeId: route.displayName
    };
    final routeByTrip = {
      for (final trip in _trips!)
        trip.tripId: routeNames[trip.routeId] ?? trip.routeId
    };
    final results = <({int departure, RouteOption route})>[];
    final outbound = <({
      String stopId,
      String tripId,
      int departure,
      int arrival,
      String route
    })>[];
    final inboundByStop = <String,
        List<({String tripId, int departure, int arrival, String route})>>{};
    for (final entry in byTrip.entries) {
      final times = entry.value
        ..sort((a, b) => a.stopSequence.compareTo(b.stopSequence));
      final fromIndex =
          times.indexWhere((time) => originIds.contains(time.stopId));
      final toIndex =
          times.indexWhere((time) => destinationIds.contains(time.stopId));
      final originalTripId = entry.key.split('#').first;
      final route = routeByTrip[originalTripId] ?? 'service';
      if (toIndex > 0) {
        final arrival =
            GtfsService.gtfsTimeToSeconds(times[toIndex].arrivalTime);
        if (arrival != null) {
          for (var i = 0; i < toIndex; i++) {
            final transferDeparture =
                GtfsService.gtfsTimeToSeconds(times[i].departureTime);
            if (transferDeparture == null) continue;
            for (final key in _transferKeys(times[i].stopId)) {
              inboundByStop.putIfAbsent(key, () => []).add((
                tripId: entry.key,
                departure: transferDeparture,
                arrival: arrival,
                route: route,
              ));
            }
          }
        }
      }
      if (fromIndex < 0) continue;
      final from = times[fromIndex];
      final depart = GtfsService.gtfsTimeToSeconds(from.departureTime);
      if (depart == null || depart < nowSeconds) continue;
      if (toIndex > fromIndex) {
        final arrive =
            GtfsService.gtfsTimeToSeconds(times[toIndex].arrivalTime);
        if (arrive != null) {
          results.add(_routeResult(depart, arrive, 'Rapid Rail · $route'));
        }
      }
      for (var i = fromIndex + 1; i < times.length; i++) {
        final arrival = GtfsService.gtfsTimeToSeconds(times[i].arrivalTime);
        if (arrival != null) {
          outbound.add((
            stopId: times[i].stopId,
            tripId: entry.key,
            departure: depart,
            arrival: arrival,
            route: route,
          ));
        }
      }
    }
    for (final first in outbound) {
      final candidates =
          <({String tripId, int departure, int arrival, String route})>[];
      for (final key in _transferKeys(first.stopId)) {
        candidates.addAll(inboundByStop[key] ?? const []);
      }
      for (final second in candidates) {
        final wait = second.departure - first.arrival;
        if (first.tripId == second.tripId || wait < 60 || wait > 1800) continue;
        results.add(_routeResult(
          first.departure,
          second.arrival,
          'Rapid Rail · ${first.route} → ${second.route}',
        ));
      }
    }
    results.sort((a, b) => a.departure.compareTo(b.departure));
    final unique = <String, RouteOption>{};
    for (final result in results) {
      final route = result.route;
      unique.putIfAbsent(
          '${route.departureTime}|${route.mode}|${route.etaSummary}',
          () => route);
    }
    return rankRoutes(unique.values);
  }

  List<RouteOption> _scanNetworkRoutes(
      Set<String> originIds, Set<String> destinationIds, int nowSeconds,
      {Map<String, int> destinationWalkSeconds = const {}}) {
    if (originIds.isEmpty || destinationIds.isEmpty) return const [];
    final stationById = {
      for (final stop in _stationDirectory ?? const <Stop>[])
        if (stop.gtfsStopId != null) stop.gtfsStopId!: stop,
    };
    final routeNames = {
      for (final route in _routes ?? const <GtfsRoute>[])
        route.routeId: route.displayName,
    };
    final routeByTrip = {
      for (final trip in _trips ?? const <GtfsTrip>[])
        trip.tripId: routeNames[trip.routeId] ?? trip.routeId,
    };
    final connections = <_TransitConnection>[];
    for (final entry in _tripInstances().entries) {
      final originalTripId = entry.key.split('#').first;
      final routeLabel = routeByTrip[originalTripId] ?? 'Rapid Rail';
      final times = [...entry.value]
        ..sort((a, b) => a.stopSequence.compareTo(b.stopSequence));
      if (times.isEmpty) continue;
      final destination =
          stationById[times.last.stopId]?.name ?? times.last.stopId;
      for (var index = 0; index + 1 < times.length; index++) {
        final departure =
            GtfsService.gtfsTimeToSeconds(times[index].departureTime);
        final arrival =
            GtfsService.gtfsTimeToSeconds(times[index + 1].arrivalTime);
        if (departure == null || arrival == null || arrival < departure) {
          continue;
        }
        connections.add(_TransitConnection(
          fromStopId: times[index].stopId,
          toStopId: times[index + 1].stopId,
          departure: departure,
          arrival: arrival,
          tripInstanceId: entry.key,
          routeLabel: routeLabel,
          destination: destination,
        ));
      }
    }
    connections.sort((a, b) => a.departure.compareTo(b.departure));
    final walking = _walkingConnections(stationById);
    final options = <RouteOption>[];

    for (final offset in const [0, 300, 600, 900, 1200]) {
      final requestedStart = nowSeconds + offset;
      final best = <String, _JourneyState>{};
      for (final originId in originIds) {
        best[originId] = _JourneyState(
          stopId: originId,
          time: requestedStart,
          departure: -1,
          tripInstanceId: null,
          rides: 0,
          steps: const [],
          routes: const [],
          checkpoints: const [],
        );
      }
      _relaxWalking(best, originIds, walking, stationById);
      for (final connection in connections) {
        if (connection.departure < requestedStart) continue;
        final state = best[connection.fromStopId];
        if (state == null) continue;
        final continuing = state.tripInstanceId == connection.tripInstanceId;
        final transferBuffer =
            state.tripInstanceId != null && !continuing ? 60 : 0;
        if (state.time + transferBuffer > connection.departure) continue;
        final rides = state.rides + (continuing ? 0 : 1);
        if (rides > 4) continue;
        final departure =
            state.departure < 0 ? connection.departure : state.departure;
        final fromName =
            stationById[connection.fromStopId]?.name ?? connection.fromStopId;
        final fromStop = stationById[connection.fromStopId];
        final steps = continuing
            ? state.steps
            : [
                ...state.steps,
                if (state.tripInstanceId != null)
                  'Change service at $fromName · allow at least 1 min',
                'Board ${connection.routeLabel} toward ${connection.destination} at $fromName at ${GtfsService.formatSecondsAsClock(connection.departure)}',
              ];
        final directionalRoute =
            '${connection.routeLabel} toward ${connection.destination}';
        final routes = continuing ||
                (state.routes.isNotEmpty &&
                    state.routes.last == directionalRoute)
            ? state.routes
            : [...state.routes, directionalRoute];
        final checkpoints = continuing || fromStop == null
            ? state.checkpoints
            : [
                ...state.checkpoints,
                RouteCheckpoint(
                  name: fromName,
                  position: fromStop.position,
                  instruction: state.tripInstanceId == null
                      ? 'Board ${connection.routeLabel} toward ${connection.destination}'
                      : 'Change to ${connection.routeLabel} toward ${connection.destination}',
                  serviceSeconds: connection.departure,
                ),
              ];
        final candidate = _JourneyState(
          stopId: connection.toStopId,
          time: connection.arrival,
          departure: departure,
          tripInstanceId: connection.tripInstanceId,
          rides: rides,
          steps: steps,
          routes: routes,
          checkpoints: checkpoints,
        );
        final existing = best[connection.toStopId];
        if (existing == null ||
            candidate.time < existing.time ||
            (candidate.time == existing.time &&
                candidate.rides < existing.rides)) {
          best[connection.toStopId] = candidate;
          _relaxWalking(best, {connection.toStopId}, walking, stationById);
        }
      }
      final destinations = destinationIds
          .map((id) => best[id])
          .whereType<_JourneyState>()
          .where((state) => state.departure >= 0)
          .toList()
        ..sort((a, b) => (a.time + (destinationWalkSeconds[a.stopId] ?? 0))
            .compareTo(b.time + (destinationWalkSeconds[b.stopId] ?? 0)));
      if (destinations.isEmpty) continue;
      final result = destinations.first;
      final destinationName = stationById[result.stopId]?.name ?? result.stopId;
      final destinationStop = stationById[result.stopId];
      options.add(RouteOption(
        departureTime: GtfsService.formatSecondsAsClock(result.departure),
        mode: result.routes.isEmpty
            ? 'Walk'
            : 'Rapid Rail · ${result.routes.join(' → ')}',
        etaSummary:
            'Arrives ${GtfsService.formatSecondsAsClock(result.time)} · ${RouteOption.formatMinutes(((result.time - result.departure) / 60).ceil())} · ${math.max(0, result.rides - 1)} transfer${result.rides == 2 ? '' : 's'}',
        status: ServiceUrgency.onTime,
        steps: [
          ...result.steps,
          'Get off at $destinationName around ${GtfsService.formatSecondsAsClock(result.time)}',
          'Follow station signs to the correct exit at $destinationName',
        ],
        checkpoints: [
          ...result.checkpoints,
          if (destinationStop != null)
            RouteCheckpoint(
              name: destinationName,
              position: destinationStop.position,
              instruction: 'Leave the service',
              serviceSeconds: result.time,
            ),
        ],
        transferCount: math.max(0, result.rides - 1),
        arrivalTime: GtfsService.formatSecondsAsClock(result.time),
        totalMinutes:
            math.max(1, ((result.time - result.departure) / 60).ceil()),
        departureServiceSeconds: result.departure,
        arrivalServiceSeconds: result.time,
        destinationStopId: result.stopId,
      ));
    }
    final unique = <String, RouteOption>{};
    for (final option in options) {
      unique.putIfAbsent(
          '${option.departureTime}|${option.mode}|${option.etaSummary}',
          () => option);
    }
    return rankRoutes(unique.values);
  }

  /// Ranks alternatives by earliest arrival, with a small transfer penalty.
  static List<RouteOption> rankRoutes(Iterable<RouteOption> routes) {
    final ranked = routes.toList()
      ..sort((a, b) {
        final aArrival =
            a.arrivalServiceSeconds == 0 ? 1 << 30 : a.arrivalServiceSeconds;
        final bArrival =
            b.arrivalServiceSeconds == 0 ? 1 << 30 : b.arrivalServiceSeconds;
        final aScore = aArrival + a.transferCount * 60;
        final bScore = bArrival + b.transferCount * 60;
        return aScore.compareTo(bScore);
      });
    return ranked
        .take(3)
        .toList()
        .asMap()
        .entries
        .map((entry) => entry.value.copyWith(isRecommended: entry.key == 0))
        .toList();
  }

  Map<String, List<_WalkingConnection>> _walkingConnections(
      Map<String, Stop> stationById) {
    const distance = Distance();
    final entries = stationById.entries.toList();
    final result = <String, List<_WalkingConnection>>{};
    for (var i = 0; i < entries.length; i++) {
      for (var j = i + 1; j < entries.length; j++) {
        final meters = distance.as(LengthUnit.Meter, entries[i].value.position,
            entries[j].value.position);
        if (meters > 450) continue;
        final seconds = math.max(60, (meters / 1.25).round());
        result
            .putIfAbsent(entries[i].key, () => [])
            .add(_WalkingConnection(entries[j].key, seconds));
        result
            .putIfAbsent(entries[j].key, () => [])
            .add(_WalkingConnection(entries[i].key, seconds));
      }
    }
    return result;
  }

  void _relaxWalking(
    Map<String, _JourneyState> best,
    Set<String> startingStops,
    Map<String, List<_WalkingConnection>> walking,
    Map<String, Stop> stationById,
  ) {
    final queue = startingStops.toList();
    while (queue.isNotEmpty) {
      queue.sort((a, b) => best[a]!.time.compareTo(best[b]!.time));
      final stopId = queue.removeAt(0);
      final state = best[stopId]!;
      for (final edge in walking[stopId] ?? const <_WalkingConnection>[]) {
        final arrival = state.time + edge.seconds;
        final existing = best[edge.toStopId];
        if (existing != null && existing.time <= arrival) continue;
        final minutes = math.max(1, (edge.seconds / 60).ceil());
        final destination = stationById[edge.toStopId]?.name ?? edge.toStopId;
        best[edge.toStopId] = _JourneyState(
          stopId: edge.toStopId,
          time: arrival,
          departure: state.departure,
          tripInstanceId: null,
          rides: state.rides,
          steps: [...state.steps, 'Walk $minutes min to $destination'],
          routes: state.routes,
          checkpoints: state.checkpoints,
        );
        queue.add(edge.toStopId);
      }
    }
  }

  ({int departure, RouteOption route}) _routeResult(
      int departure, int arrival, String mode) {
    return (
      departure: departure,
      route: RouteOption(
        departureTime: GtfsService.formatSecondsAsClock(departure),
        mode: mode,
        etaSummary:
            'Arrives ${GtfsService.formatSecondsAsClock(arrival)} · ${RouteOption.formatMinutes(((arrival - departure) / 60).ceil())}',
        status: ServiceUrgency.onTime,
        arrivalTime: GtfsService.formatSecondsAsClock(arrival),
        totalMinutes: math.max(1, ((arrival - departure) / 60).ceil()),
        departureServiceSeconds: departure,
        arrivalServiceSeconds: arrival,
      ),
    );
  }

  Iterable<String> _transferKeys(String stopId) sync* {
    yield stopId;
    Stop? stop;
    for (final item in _stationDirectory ?? const <Stop>[]) {
      if (item.gtfsStopId == stopId) {
        stop = item;
        break;
      }
    }
    if (stop != null) {
      yield stop.name
          .toLowerCase()
          .replaceAll(RegExp(r'\b(mrt|lrt|monorail|station|platform)\b'), '')
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim();
    }
  }

  Future<void> _ensureStationDirectory() async {
    if (_stationDirectory != null) return;
    try {
      final gtfsStops = await GtfsService.fetchStops(category: 'rapid-rail-kl');
      _stationDirectory = gtfsStops
          .map((stop) => Stop(
                name: stop.name,
                platform: 'Rapid Rail station',
                position: LatLng(stop.lat, stop.lon),
                timeToDeparture: Duration.zero,
                urgency: ServiceUrgency.onTime,
                gtfsStopId: stop.stopId,
              ))
          .toList();
      _lastSource = TransitDataSource.official;
    } catch (_) {
      _stationDirectory = _cachedStops ?? const [];
      _lastSource = _stationDirectory!.isEmpty
          ? TransitDataSource.unavailable
          : TransitDataSource.cached;
    }
  }

  /// Loads the schedule once and calculates each station's next departure,
  /// urgency, and last service for today's active service IDs.
  Future<List<Stop>> _withRealSchedule(List<Stop> stops) async {
    try {
      await _ensureScheduleLoaded();
    } catch (_) {
      return stops;
    }
    if (_stopTimes == null || _activeTripIds == null) return stops;

    final now = DateTime.now();
    final nowSeconds = GtfsService.secondsIntoServiceDay(now);

    final schedules = _directionSchedules();

    return stops.map((stop) {
      final gtfsId = stop.gtfsStopId;
      if (gtfsId == null) return stop;
      final stationSchedules = schedules[gtfsId]?.values.toList() ?? const [];
      if (stationSchedules.isEmpty) {
        return stop.copyWith(
          platform: 'Rail station',
          hasDepartureData: false,
          isOperating: false,
        );
      }
      final options = stationSchedules
          .map((schedule) => _directionOption(stop, schedule, nowSeconds))
          .toList()
        ..sort((a, b) {
          if (a.isOperating != b.isOperating) return a.isOperating ? -1 : 1;
          return a.timeToDeparture.compareTo(b.timeToDeparture);
        });
      final selected = options.first;
      return stop
          .copyWith(
            directionOptions: options,
            selectedDirectionKey: selected.key,
          )
          .withDirection(selected.key);
    }).toList();
  }

  Map<String, Map<String, _DirectionSchedule>> _directionSchedules() {
    final routesById = {
      for (final route in _routes ?? const <GtfsRoute>[]) route.routeId: route,
    };
    final tripsById = {
      for (final trip in _trips ?? const <GtfsTrip>[]) trip.tripId: trip,
    };
    final stopNames = {
      for (final stop in _stationDirectory ?? const <Stop>[])
        if (stop.gtfsStopId != null) stop.gtfsStopId!: stop.name,
    };
    final schedules = <String, Map<String, _DirectionSchedule>>{};
    for (final instance in _tripInstances().entries) {
      final tripId = instance.key.split('#').first;
      final trip = tripsById[tripId];
      final route = trip == null ? null : routesById[trip.routeId];
      if (trip == null || route == null || instance.value.isEmpty) continue;
      final times = [...instance.value]
        ..sort((a, b) => a.stopSequence.compareTo(b.stopSequence));
      final terminalId = times.last.stopId;
      final destination = stopNames[terminalId] ?? terminalId;
      final key = '${trip.routeId}|${trip.directionId ?? 'x'}|$terminalId';
      // The final row is an arrival at the terminal, not a departure toward it.
      for (final time in times.take(times.length - 1)) {
        final seconds = GtfsService.gtfsTimeToSeconds(time.departureTime) ??
            GtfsService.gtfsTimeToSeconds(time.arrivalTime);
        if (seconds == null) continue;
        schedules
            .putIfAbsent(time.stopId, () => {})
            .putIfAbsent(
              key,
              () => _DirectionSchedule(
                key: key,
                destination: destination,
                routeLabel: route.displayName,
                transportMode: route.modeLabel,
              ),
            )
            .departureSeconds
            .add(seconds);
      }
    }
    return schedules;
  }

  TransitDirectionOption _directionOption(
      Stop stop, _DirectionSchedule schedule, int nowSeconds) {
    final scheduled = applyScheduleWindow(
      stop: stop,
      departureSeconds: schedule.departureSeconds,
      nowSeconds: nowSeconds,
      modeLabel: schedule.transportMode,
      routeLabel: schedule.routeLabel,
    );
    return TransitDirectionOption(
      key: schedule.key,
      destination: schedule.destination,
      routeLabel: schedule.routeLabel,
      transportMode: schedule.transportMode,
      timeToDeparture: scheduled.timeToDeparture,
      urgency: scheduled.urgency,
      lastService: scheduled.lastService,
      hasDepartureData: scheduled.hasDepartureData,
      isOperating: scheduled.isOperating,
    );
  }

  /// Applies a published first/last-service window to a stop. Kept public and
  /// deterministic so early-morning and after-last-service behavior is tested.
  static Stop applyScheduleWindow({
    required Stop stop,
    required List<int> departureSeconds,
    required int nowSeconds,
    required String modeLabel,
    String routeLabel = '',
  }) {
    final times = [...departureSeconds]..sort();
    if (times.isEmpty) {
      return stop.copyWith(
        platform: '$modeLabel station',
        transportMode: modeLabel,
        routeLabel: routeLabel,
        hasDepartureData: false,
        isOperating: false,
      );
    }
    final upcoming = times.where((time) => time > nowSeconds);
    final lastServiceLabel = GtfsService.formatSecondsAsClock(times.last);
    final isOperating = nowSeconds >= times.first && nowSeconds < times.last;
    if (!isOperating || upcoming.isEmpty) {
      return stop.copyWith(
        platform: '$modeLabel station',
        timeToDeparture: Duration.zero,
        urgency: ServiceUrgency.critical,
        lastService: lastServiceLabel,
        transportMode: modeLabel,
        routeLabel: routeLabel,
        hasDepartureData: true,
        isOperating: false,
      );
    }
    final remaining = Duration(seconds: upcoming.first - nowSeconds);
    final urgency = remaining <= const Duration(minutes: 5)
        ? ServiceUrgency.critical
        : remaining <= const Duration(minutes: 20)
            ? ServiceUrgency.closingSoon
            : ServiceUrgency.onTime;
    return stop.copyWith(
      platform: '$modeLabel station',
      timeToDeparture: remaining,
      urgency: urgency,
      lastService: lastServiceLabel,
      transportMode: modeLabel,
      routeLabel: routeLabel,
      hasDepartureData: true,
      isOperating: true,
    );
  }

  Future<void> _ensureScheduleLoaded() async {
    final now = DateTime.now();
    final serviceDate = GtfsService.serviceDateFor(now);
    final dateStamp = GtfsService.dateStamp(serviceDate);
    if (_stopTimes != null &&
        _trips != null &&
        _calendar != null &&
        _calendarDates != null &&
        _routes != null &&
        _frequencies != null &&
        _activeDate == dateStamp) {
      return;
    }
    final results = await Future.wait([
      GtfsService.fetchStopTimes(category: 'rapid-rail-kl'),
      GtfsService.fetchTrips(category: 'rapid-rail-kl'),
      GtfsService.fetchCalendar(category: 'rapid-rail-kl'),
      GtfsService.fetchCalendarDates(category: 'rapid-rail-kl'),
      GtfsService.fetchRoutes(category: 'rapid-rail-kl'),
      GtfsService.fetchFrequencies(category: 'rapid-rail-kl'),
    ]);
    _stopTimes = results[0] as List<GtfsStopTime>;
    _trips = results[1] as List<GtfsTrip>;
    _calendar = results[2] as List<GtfsCalendarService>;
    _calendarDates = results[3] as List<GtfsCalendarDate>;
    _routes = results[4] as List<GtfsRoute>;
    _frequencies = results[5] as List<GtfsFrequency>;
    _activeTripIds = GtfsService.activeTripIds(
      trips: _trips!,
      calendar: _calendar!,
      calendarDates: _calendarDates!,
      serviceDate: serviceDate,
    );
    _activeDate = dateStamp;
  }

  /// Expands frequency-based template trips into their actual service-day
  /// instances. Feeds without frequencies keep their listed stop times.
  Map<String, List<GtfsStopTime>> _tripInstances() {
    final templates = <String, List<GtfsStopTime>>{};
    for (final stopTime in _stopTimes ?? const <GtfsStopTime>[]) {
      if (_activeTripIds?.contains(stopTime.tripId) ?? false) {
        templates.putIfAbsent(stopTime.tripId, () => []).add(stopTime);
      }
    }
    final frequenciesByTrip = <String, List<GtfsFrequency>>{};
    for (final frequency in _frequencies ?? const <GtfsFrequency>[]) {
      frequenciesByTrip.putIfAbsent(frequency.tripId, () => []).add(frequency);
    }
    final instances = <String, List<GtfsStopTime>>{};
    for (final entry in templates.entries) {
      final times = entry.value
        ..sort((a, b) => a.stopSequence.compareTo(b.stopSequence));
      final frequencyRows = frequenciesByTrip[entry.key];
      if (frequencyRows == null || frequencyRows.isEmpty) {
        instances[entry.key] = times;
        continue;
      }
      final templateStart = GtfsService.gtfsTimeToSeconds(
          times.first.departureTime.isNotEmpty
              ? times.first.departureTime
              : times.first.arrivalTime);
      if (templateStart == null) continue;
      for (final frequency in frequencyRows) {
        final start = GtfsService.gtfsTimeToSeconds(frequency.startTime);
        final end = GtfsService.gtfsTimeToSeconds(frequency.endTime);
        if (start == null || end == null) continue;
        for (var departure = start;
            departure < end;
            departure += frequency.headwaySeconds) {
          final offset = departure - templateStart;
          instances['${entry.key}#$departure'] = times
              .map((time) => GtfsStopTime(
                    tripId: time.tripId,
                    stopId: time.stopId,
                    arrivalTime: _shiftGtfsTime(time.arrivalTime, offset),
                    departureTime: _shiftGtfsTime(time.departureTime, offset),
                    stopSequence: time.stopSequence,
                  ))
              .toList();
        }
      }
    }
    return instances;
  }

  String _shiftGtfsTime(String value, int offset) {
    final seconds = GtfsService.gtfsTimeToSeconds(value);
    if (seconds == null) return value;
    final shifted = seconds + offset;
    final hours = shifted ~/ 3600;
    final minutes = (shifted % 3600) ~/ 60;
    final remainder = shifted % 60;
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${remainder.toString().padLeft(2, '0')}';
  }
}

class _TransitConnection {
  final String fromStopId;
  final String toStopId;
  final int departure;
  final int arrival;
  final String tripInstanceId;
  final String routeLabel;
  final String destination;

  const _TransitConnection({
    required this.fromStopId,
    required this.toStopId,
    required this.departure,
    required this.arrival,
    required this.tripInstanceId,
    required this.routeLabel,
    required this.destination,
  });
}

class _DirectionSchedule {
  final String key;
  final String destination;
  final String routeLabel;
  final String transportMode;
  final List<int> departureSeconds = [];

  _DirectionSchedule({
    required this.key,
    required this.destination,
    required this.routeLabel,
    required this.transportMode,
  });
}

class _WalkingConnection {
  final String toStopId;
  final int seconds;
  const _WalkingConnection(this.toStopId, this.seconds);
}

class _JourneyState {
  final String stopId;
  final int time;
  final int departure;
  final String? tripInstanceId;
  final int rides;
  final List<String> steps;
  final List<String> routes;
  final List<RouteCheckpoint> checkpoints;

  const _JourneyState({
    required this.stopId,
    required this.time,
    required this.departure,
    required this.tripInstanceId,
    required this.rides,
    required this.steps,
    required this.routes,
    required this.checkpoints,
  });
}
