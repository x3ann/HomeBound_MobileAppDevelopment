import 'package:flutter/material.dart';
import '../../services/transit_repository.dart';
import '../theme/app_theme.dart';

/// Small pill shown near stop listings so it's always honest about
/// whether the app is showing live GTFS data or the offline/mock fallback.
class DataSourceBadge extends StatelessWidget {
  final TransitDataSource source;
  const DataSourceBadge({super.key, required this.source});

  @override
  Widget build(BuildContext context) {
    final bool isLive =
        source == TransitDataSource.live || source == TransitDataSource.cached;
    final color = isLive ? AppColors.success : AppColors.textSecondary;
    final label = isLive ? 'Live GTFS data' : 'Offline demo data';
    final icon = isLive ? Icons.wifi_rounded : Icons.wifi_off_rounded;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 10, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
