import 'package:flutter/material.dart';
import '../../../shared/models/stop.dart';
import '../../../shared/theme/app_theme.dart';

/// Single row in the "Nearby Stops" list — used on both the dashboard and
/// the Live Map screen so they always stay visually in sync.
class StopTile extends StatelessWidget {
  final Stop stop;
  const StopTile({super.key, required this.stop});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
          color: AppColors.surface, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: stop.urgency.color, shape: BoxShape.circle)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(stop.name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  stop.distanceMeters == null
                      ? stop.platform
                      : '${stop.platform} · ${_distance(stop.distanceMeters!)}',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(stop.formattedCountdown,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: stop.urgency.color,
                      fontSize: 13)),
              Text(stop.serviceStatusLabel,
                  style: const TextStyle(
                      fontSize: 10, color: AppColors.textSecondary)),
            ],
          ),
        ],
      ),
    );
  }

  String _distance(double meters) => meters < 1000
      ? '${meters.round()} m away'
      : '${(meters / 1000).toStringAsFixed(1)} km away';
}
