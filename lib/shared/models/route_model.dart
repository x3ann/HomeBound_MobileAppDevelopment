import '../theme/app_theme.dart';
import 'package:latlong2/latlong.dart';

class RouteCheckpoint {
  final String name;
  final LatLng position;
  final String instruction;
  final int serviceSeconds;

  const RouteCheckpoint({
    required this.name,
    required this.position,
    required this.instruction,
    this.serviceSeconds = 0,
  });
}

/// A single candidate route/departure returned by the planner.
class RouteOption {
  final String departureTime;
  final String mode; // e.g. "LRT · MRT"
  final String etaSummary; // e.g. "Arrives 12:04 AM · 22 min"
  final ServiceUrgency status;
  final List<String> steps;
  final int transferCount;
  final String arrivalTime;
  final int totalMinutes;
  final bool isRecommended;
  final int departureServiceSeconds;
  final int arrivalServiceSeconds;
  final List<RouteCheckpoint> checkpoints;
  final String? destinationStopId;

  const RouteOption({
    required this.departureTime,
    required this.mode,
    required this.etaSummary,
    required this.status,
    this.steps = const [],
    this.transferCount = 0,
    this.arrivalTime = '',
    this.totalMinutes = 0,
    this.isRecommended = false,
    this.departureServiceSeconds = 0,
    this.arrivalServiceSeconds = 0,
    this.checkpoints = const [],
    this.destinationStopId,
  });

  RouteOption copyWith({bool? isRecommended}) => RouteOption(
        departureTime: departureTime,
        mode: mode,
        etaSummary: etaSummary,
        status: status,
        steps: steps,
        transferCount: transferCount,
        arrivalTime: arrivalTime,
        totalMinutes: totalMinutes,
        isRecommended: isRecommended ?? this.isRecommended,
        departureServiceSeconds: departureServiceSeconds,
        arrivalServiceSeconds: arrivalServiceSeconds,
        checkpoints: checkpoints,
        destinationStopId: destinationStopId,
      );

  /// Start of the whole displayed journey, including access walk and waiting.
  int get journeyStartServiceSeconds {
    if (arrivalServiceSeconds <= 0 || totalMinutes <= 0) {
      return departureServiceSeconds;
    }
    final derived = arrivalServiceSeconds - totalMinutes * 60;
    if (departureServiceSeconds <= 0) return derived;
    return derived < departureServiceSeconds
        ? derived
        : departureServiceSeconds;
  }

  double progressAt(int serviceSeconds) {
    final start = journeyStartServiceSeconds;
    final end = arrivalServiceSeconds;
    if (start <= 0 || end <= start) return 0;
    return ((serviceSeconds - start) / (end - start)).clamp(0.0, 1.0);
  }

  String get durationLabel => formatMinutes(totalMinutes);

  static String formatMinutes(int minutes) {
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final remainder = minutes.remainder(60);
    return remainder == 0 ? '${hours}h' : '${hours}h ${remainder}m';
  }

  int activeCheckpointAt(int serviceSeconds) {
    if (checkpoints.isEmpty) return 0;
    final timed = checkpoints
        .asMap()
        .entries
        .where((entry) => entry.value.serviceSeconds > 0)
        .toList();
    if (timed.isNotEmpty) {
      var active = timed.first.key;
      for (final entry in timed) {
        if (serviceSeconds < entry.value.serviceSeconds) break;
        active = entry.key;
      }
      return active.clamp(0, checkpoints.length - 1);
    }
    return (progressAt(serviceSeconds) * checkpoints.length)
        .floor()
        .clamp(0, checkpoints.length - 1);
  }
}
