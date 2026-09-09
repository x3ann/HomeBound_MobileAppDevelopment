import 'package:flutter/material.dart';
import '../../../shared/models/stop.dart';
import '../../../shared/theme/app_theme.dart';

/// The coloured pin dropped on the map for each stop. Colour follows the
/// stop's urgency so it always matches the Last Service Tracker chips.
class StopPin extends StatelessWidget {
  final Stop stop;
  const StopPin({super.key, required this.stop});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '${stop.name}\n${stop.formattedCountdown}',
      child: Container(
        decoration: BoxDecoration(
          color: stop.urgency.color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [
            BoxShadow(
              color: stop.urgency.color.withValues(alpha: 0.6),
              blurRadius: 8,
            ),
          ],
        ),
        child: const Icon(
          Icons.directions_transit_rounded,
          color: Colors.white,
          size: 18,
        ),
      ),
    );
  }
}
