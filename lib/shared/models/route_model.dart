import '../theme/app_theme.dart';

/// A single candidate route/departure returned by the planner.
class RouteOption {
  final String departureTime;
  final String mode; // e.g. "LRT · MRT"
  final String etaSummary; // e.g. "Arrives 12:04 AM · 22 min"
  final ServiceUrgency status;

  const RouteOption({
    required this.departureTime,
    required this.mode,
    required this.etaSummary,
    required this.status,
  });
}
