import 'package:latlong2/latlong.dart';
import '../shared/models/stop.dart';
import '../shared/models/route_model.dart';
import '../shared/theme/app_theme.dart';
import 'gtfs_models.dart';
import 'gtfs_service.dart';
import 'experimental_rail_service.dart';

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
      merged = await _withRealSchedule(merged);
      _cachedStops = merged;
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

  /// Official station directory for origin and destination autocomplete.
  Future<List<Stop>> searchStops(String query) async {
    await _ensureStationDirectory();
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final matches = _stationDirectory!
        .where((stop) => stop.name.toLowerCase().contains(needle))
        .toList();
    matches.sort((a, b) {
      final aName = a.name.toLowerCase();
      final bName = b.name.toLowerCase();
      final aRank = aName == needle ? 0 : (aName.startsWith(needle) ? 1 : 2);
      final bRank = bName == needle ? 0 : (bName.startsWith(needle) ? 1 : 2);
      return aRank != bRank ? aRank.compareTo(bRank) : aName.compareTo(bName);
    });
    return matches.take(6).toList();
  }

  /// Finds direct or one-interchange scheduled GTFS rail journeys.
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
          ).take(1).toList();
    final destinations = await searchStops(destinationName);
    if (origins.isEmpty || destinations.isEmpty) return const [];
    await _ensureScheduleLoaded();
    final originIds =
        origins.map((stop) => stop.gtfsStopId).whereType<String>().toSet();
    final destinationIds =
        destinations.map((stop) => stop.gtfsStopId).whereType<String>().toSet();
    if (originIds.isEmpty || destinationIds.isEmpty) return const [];
    final now = DateTime.now();
    final nowSeconds = now.hour * 3600 + now.minute * 60 + now.second;
    final byTrip = _tripInstances();
    final routeNames = {
      for (final route in _routes!)
        route.routeId: route.shortName.trim().isNotEmpty
            ? route.shortName.trim()
            : route.longName.trim()
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
    return unique.values.take(3).toList();
  }

  ({int departure, RouteOption route}) _routeResult(
      int departure, int arrival, String mode) {
    return (
      departure: departure,
      route: RouteOption(
        departureTime: GtfsService.formatSecondsAsClock(departure),
        mode: mode,
        etaSummary:
            'Arrives ${GtfsService.formatSecondsAsClock(arrival)} · ${(arrival - departure) ~/ 60} min',
        status: ServiceUrgency.onTime,
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
    } catch (_) {
      _stationDirectory = _cachedStops ?? const [];
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
    final nowSeconds = now.hour * 3600 + now.minute * 60 + now.second;

    final timesByStop = <String, List<int>>{};
    for (final instance in _tripInstances().values) {
      for (final st in instance) {
        final seconds = GtfsService.gtfsTimeToSeconds(st.departureTime) ??
            GtfsService.gtfsTimeToSeconds(st.arrivalTime);
        if (seconds == null) continue;
        timesByStop.putIfAbsent(st.stopId, () => []).add(seconds);
      }
    }

    return stops.map((stop) {
      final gtfsId = stop.gtfsStopId;
      if (gtfsId == null) return stop;
      final times = timesByStop[gtfsId];
      if (times == null || times.isEmpty) return stop;
      times.sort();

      final upcoming = times.where((t) => t > nowSeconds);
      final lastServiceLabel = GtfsService.formatSecondsAsClock(times.last);

      if (upcoming.isEmpty) {
        // Every scheduled departure for today has already passed.
        return stop.copyWith(
          timeToDeparture: Duration.zero,
          urgency: ServiceUrgency.critical,
          lastService: lastServiceLabel,
        );
      }

      final nextSeconds = upcoming.first;
      final remaining = Duration(seconds: nextSeconds - nowSeconds);
      final urgency = remaining.inMinutes <= 5
          ? ServiceUrgency.critical
          : remaining.inMinutes <= 20
              ? ServiceUrgency.closingSoon
              : ServiceUrgency.onTime;

      return stop.copyWith(
        timeToDeparture: remaining,
        urgency: urgency,
        lastService: lastServiceLabel,
      );
    }).toList();
  }

  Future<void> _ensureScheduleLoaded() async {
    final now = DateTime.now();
    final dateStamp = _dateStamp(now);
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
    _activeTripIds =
        _computeActiveTripIds(_trips!, _calendar!, _calendarDates!, now);
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

  Set<String> _computeActiveTripIds(
    List<GtfsTrip> trips,
    List<GtfsCalendarService> calendar,
    List<GtfsCalendarDate> calendarDates,
    DateTime today,
  ) {
    final todayStamp = _dateStamp(today);

    bool runsToday(GtfsCalendarService service) {
      final withinRange = (service.startDate.isEmpty ||
              todayStamp.compareTo(service.startDate) >= 0) &&
          (service.endDate.isEmpty ||
              todayStamp.compareTo(service.endDate) <= 0);
      if (!withinRange) return false;
      switch (today.weekday) {
        case DateTime.monday:
          return service.monday;
        case DateTime.tuesday:
          return service.tuesday;
        case DateTime.wednesday:
          return service.wednesday;
        case DateTime.thursday:
          return service.thursday;
        case DateTime.friday:
          return service.friday;
        case DateTime.saturday:
          return service.saturday;
        case DateTime.sunday:
        default:
          return service.sunday;
      }
    }

    final activeServiceIds =
        calendar.where(runsToday).map((s) => s.serviceId).toSet();
    for (final exception in calendarDates.where((e) => e.date == todayStamp)) {
      if (exception.exceptionType == 1) {
        activeServiceIds.add(exception.serviceId);
      } else {
        activeServiceIds.remove(exception.serviceId);
      }
    }
    return trips
        .where((t) => activeServiceIds.contains(t.serviceId))
        .map((t) => t.tripId)
        .toSet();
  }

  String _dateStamp(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
}
