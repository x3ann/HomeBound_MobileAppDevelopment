import '../theme/app_theme.dart';

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
      );
}
