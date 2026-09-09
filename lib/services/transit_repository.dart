import 'package:latlong2/latlong.dart';
import '../shared/models/stop.dart';
import '../shared/theme/app_theme.dart';
import 'gtfs_models.dart';
import 'gtfs_service.dart';

/// Where the currently-displayed stop data came from. Surfaced in the UI
/// (small badge) so it's honest about whether a session is live or offline.
enum TransitDataSource { live, cached, mock }

class TransitLookupResult {
  final List<Stop> stops;
  final TransitDataSource source;
  const TransitLookupResult(this.stops, this.source);
}

/// Single source of truth for "what stops should the app show right now".
///
/// Tries the real GTFS Static API (api.data.gov.my, no key required) first.
/// On success, real station names/coordinates from the feed are merged
/// into our known stop list by fuzzy name match, and — new — real
/// schedule data (stop_times.txt + trips.txt + calendar.txt, filtered to
/// today's active services) is used to compute an actual "next departure"
/// countdown and "last service" time per stop.
///
/// On any failure (offline, feed down, rate-limited, unexpected format),
/// this silently falls back to MockData so the app never breaks a demo.
class TransitRepository {
  TransitRepository._();
  static final TransitRepository instance = TransitRepository._();

  List<Stop>? _cachedStops;
  List<Stop>? _stationDirectory;
  TransitDataSource _lastSource = TransitDataSource.mock;

  List<GtfsStopTime>? _stopTimes;
  List<GtfsTrip>? _trips;
  List<GtfsCalendarService>? _calendar;
  Set<String>? _activeTripIds;

  TransitDataSource get lastSource => _lastSource;

  Future<TransitLookupResult> getNearbyStops(
      {bool forceRefresh = false}) async {
    if (_cachedStops != null && !forceRefresh) {
      return TransitLookupResult(_cachedStops!, TransitDataSource.cached);
    }

    try {
      final gtfsStops = await GtfsService.fetchStops(category: 'rapid-rail-kl');
      var merged = _mergeWithMock(gtfsStops);
      merged = await _withRealSchedule(merged);
      _cachedStops = merged;
      _lastSource = TransitDataSource.live;
      return TransitLookupResult(merged, TransitDataSource.live);
    } catch (_) {
      // Network unavailable, feed changed shape, rate limited, etc.
      // Fall back to mock data rather than showing an error screen — last-
      // service info during a genuine outage is exactly when this app
      // most needs to still work.
      _cachedStops = MockData.nearbyStops;
      _lastSource = TransitDataSource.mock;
      return TransitLookupResult(MockData.nearbyStops, TransitDataSource.mock);
    }
  }

  /// Orders the available stop list by walking distance from a device location.
  /// The distance is calculated locally, so this still works with cached data.
  List<Stop> sortByDistance(List<Stop> stops, LatLng userLocation) {
    const distance = Distance();
    final ordered = [...stops];
    ordered.sort((a, b) => distance
        .as(LengthUnit.Meter, userLocation, a.position)
        .compareTo(distance.as(LengthUnit.Meter, userLocation, b.position)));
    return ordered;
  }

  /// Station directory for destination autocomplete. It contains the actual
  /// GTFS station names where online, with the app's known stops as fallback.
  Future<List<Stop>> searchStops(String query) async {
    if (_stationDirectory == null) {
      try {
        final gtfsStops =
        await GtfsService.fetchStops(category: 'rapid-rail-kl');
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
        _stationDirectory = MockData.nearbyStops;
      }
    }
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    return _stationDirectory!
        .where((stop) => stop.name.toLowerCase().contains(needle))
        .take(6)
        .toList();
  }

  /// Replaces each mock stop's coordinates/id with the real GTFS entry
  /// whose name contains ours (case-insensitive), when one exists. Keeps
  /// our simulated platform label either way.
  List<Stop> _mergeWithMock(List<GtfsStop> gtfsStops) {
    return MockData.nearbyStops.map((mock) {
      final target = _stripSuffix(mock.name).toLowerCase();
      GtfsStop? match;
      for (final g in gtfsStops) {
        if (g.name.toLowerCase().contains(target)) {
          match = g;
          break;
        }
      }
      if (match == null) return mock;
      return mock.copyWith(
        position: LatLng(match.lat, match.lon),
        gtfsStopId: match.stopId,
      );
    }).toList();
  }

  String _stripSuffix(String name) {
    // "Pasar Seni LRT" -> "Pasar Seni" so it matches GTFS naming variants.
    return name
        .replaceAll(RegExp(r'\s+(LRT|MRT|Station)$', caseSensitive: false), '')
        .trim();
  }

  /// Loads stop_times/trips/calendar once (lazily) and rewrites each
  /// stop's timeToDeparture/urgency/lastService using the *real* schedule
  /// for today, for any stop that matched a live gtfsStopId. Stops that
  /// didn't match keep their mock schedule. Any failure here is silent —
  /// the app still has valid station names/positions from stops.txt even
  /// if the heavier schedule files can't be loaded.
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
    for (final st in _stopTimes!) {
      if (!_activeTripIds!.contains(st.tripId)) continue;
      final seconds = GtfsService.gtfsTimeToSeconds(st.departureTime) ??
          GtfsService.gtfsTimeToSeconds(st.arrivalTime);
      if (seconds == null) continue;
      timesByStop.putIfAbsent(st.stopId, () => []).add(seconds);
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
    if (_stopTimes != null && _trips != null && _calendar != null) return;
    final results = await Future.wait([
      GtfsService.fetchStopTimes(category: 'rapid-rail-kl'),
      GtfsService.fetchTrips(category: 'rapid-rail-kl'),
      GtfsService.fetchCalendar(category: 'rapid-rail-kl'),
    ]);
    _stopTimes = results[0] as List<GtfsStopTime>;
    _trips = results[1] as List<GtfsTrip>;
    _calendar = results[2] as List<GtfsCalendarService>;
    _activeTripIds = _computeActiveTripIds(_trips!, _calendar!, DateTime.now());
  }

  Set<String> _computeActiveTripIds(
      List<GtfsTrip> trips,
      List<GtfsCalendarService> calendar,
      DateTime today,
      ) {
    final todayStamp =
        '${today.year.toString().padLeft(4, '0')}${today.month.toString().padLeft(2, '0')}${today.day.toString().padLeft(2, '0')}';

    bool runsToday(GtfsCalendarService service) {
      final withinRange =
          (service.startDate.isEmpty || todayStamp.compareTo(service.startDate) >= 0) &&
              (service.endDate.isEmpty || todayStamp.compareTo(service.endDate) <= 0);
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
    return trips
        .where((t) => activeServiceIds.contains(t.serviceId))
        .map((t) => t.tripId)
        .toSet();
  }
}