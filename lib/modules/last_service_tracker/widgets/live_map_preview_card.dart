import 'package:flutter/material.dart';
import '../../../shared/theme/app_theme.dart';

/// Small "Live Map" teaser card on the dashboard. Purely presentational —
/// tapping it is handled by the parent screen (switches bottom nav tab).
class LiveMapPreviewCard extends StatelessWidget {
  final int nearbyCount;
  final int criticalCount;
  final VoidCallback? onTap;

  const LiveMapPreviewCard({
    super.key,
    required this.nearbyCount,
    required this.criticalCount,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 110,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            const Icon(Icons.map_rounded, color: AppColors.gold, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Live Map',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('$nearbyCount stops nearby · $criticalCount critical',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_rounded,
                color: AppColors.textSecondary, size: 18),
          ],
        ),
      ),
    );
  }
}
