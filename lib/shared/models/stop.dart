import 'package:latlong2/latlong.dart';
import '../theme/app_theme.dart';

/// A transit stop/station shown on the Last Service Tracker and Live Map.
///
/// `position`, `name`, `gtfsStopId`, `timeToDeparture`, `urgency` and
/// `lastService` are populated from the live GTFS Static feed
/// (stops.txt + stop_times.txt + trips.txt + calendar.txt) by
/// TransitRepository whenever a stop is successfully matched to the feed.
class Stop {
  final String name;
  final String platform;
  final LatLng position;
  final Duration timeToDeparture;
  final ServiceUrgency urgency;
  final String? gtfsStopId;
  final String lastService;
  final String? liveRailEstimate;
  final double? distanceMeters;
  final String transportMode;
  final String routeLabel;
  final bool hasDepartureData;
  final bool isOperating;
  final bool isLiveEstimate;

  const Stop({
    required this.name,
    required this.platform,
    required this.position,
    required this.timeToDeparture,
    required this.urgency,
    this.gtfsStopId,
    this.lastService = '—',
    this.liveRailEstimate,
    this.distanceMeters,
    this.transportMode = 'Rail',
    this.routeLabel = '',
    this.hasDepartureData = true,
    this.isOperating = true,
    this.isLiveEstimate = false,
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
    double? distanceMeters,
    String? transportMode,
    String? routeLabel,
    bool? hasDepartureData,
    bool? isOperating,
    bool? isLiveEstimate,
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
      distanceMeters: distanceMeters ?? this.distanceMeters,
      transportMode: transportMode ?? this.transportMode,
      routeLabel: routeLabel ?? this.routeLabel,
      hasDepartureData: hasDepartureData ?? this.hasDepartureData,
      isOperating: isOperating ?? this.isOperating,
      isLiveEstimate: isLiveEstimate ?? this.isLiveEstimate,
    );
  }

  String get formattedCountdown {
    if (!isOperating) return 'Out of service';
    if (!hasDepartureData) return 'ETA unavailable';
    if (timeToDeparture <= Duration.zero) return 'No more today';
    final h = timeToDeparture.inHours;
    final m = timeToDeparture.inMinutes.remainder(60);
    final s = timeToDeparture.inSeconds.remainder(60);
    return h > 0 ? '${h}h ${m}m' : '${m}m ${s.toString().padLeft(2, '0')}s';
  }

  String get serviceStatusLabel {
    if (!isOperating) return 'OUT OF SERVICE';
    if (!hasDepartureData) return 'SCHEDULED STOP';
    return urgency.label;
  }
}
