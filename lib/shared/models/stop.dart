import 'package:latlong2/latlong.dart';
import '../theme/app_theme.dart';

/// A transit stop/station shown on the Last Service Tracker and Live Map.
///
/// `position`, `name`, `gtfsStopId`, `timeToDeparture`, `urgency` and
/// `lastService` are populated from the live GTFS Static feed
/// (stops.txt + stop_times.txt + trips.txt + calendar.txt) by
/// TransitRepository whenever a stop is successfully matched to the feed.
/// If the feed is unavailable, stops fall back to the mock values below.
class Stop {
  final String name;
  final String platform;
  final LatLng position;
  final Duration timeToDeparture;
  final ServiceUrgency urgency;
  final String? gtfsStopId;
  final String lastService;
  final String? liveRailEstimate;

  const Stop({
    required this.name,
    required this.platform,
    required this.position,
    required this.timeToDeparture,
    required this.urgency,
    this.gtfsStopId,
    this.lastService = '—',
    this.liveRailEstimate,
  });

  Stop copyWith({
    String? name,
    String? platform,
    LatLng? position,
    Duration? timeToDeparture,
    ServiceUrgency? urgency,
    String? gtfsStopId,
    String? lastService,
    String? liveRailEstimate,
  }) {
    return Stop(
      name: name ?? this.name,
      platform: platform ?? this.platform,
      position: position ?? this.position,
      timeToDeparture: timeToDeparture ?? this.timeToDeparture,
      urgency: urgency ?? this.urgency,
      gtfsStopId: gtfsStopId ?? this.gtfsStopId,
      lastService: lastService ?? this.lastService,
      liveRailEstimate: liveRailEstimate ?? this.liveRailEstimate,
    );
  }

  String get formattedCountdown {
    final m = timeToDeparture.inMinutes.remainder(60);
    final s = timeToDeparture.inSeconds.remainder(60);
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }
}

/// Mock dataset used only as an offline fallback when the live GTFS feed
/// (stops/schedules) can't be reached. TransitRepository overwrites the
/// countdown/urgency/lastService fields with real schedule data whenever
/// a stop successfully matches the live feed.
class MockData {
  static const List<Stop> nearbyStops = [
    Stop(
      name: 'Pasar Seni LRT',
      platform: 'Platform 2 · Kelana Jaya Line',
      position: LatLng(3.1424, 101.6959),
      timeToDeparture: Duration(minutes: 6, seconds: 11),
      urgency: ServiceUrgency.critical,
      lastService: '11:58 PM',
    ),
    Stop(
      name: 'KL Sentral',
      platform: 'Platform 1 · KTM Komuter',
      position: LatLng(3.1341, 101.6866),
      timeToDeparture: Duration(minutes: 18, seconds: 42),
      urgency: ServiceUrgency.closingSoon,
      lastService: '11:58 PM',
    ),
    Stop(
      name: 'Masjid Jamek',
      platform: 'Platform 3 · Ampang Line',
      position: LatLng(3.1488, 101.6956),
      timeToDeparture: Duration(minutes: 34),
      urgency: ServiceUrgency.onTime,
      lastService: '11:58 PM',
    ),
  ];
}
