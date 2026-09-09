import 'package:flutter/material.dart';
import '../../../shared/models/route_model.dart';
import '../../../shared/theme/app_theme.dart';

/// Single ranked route result: departure time, status chip, mode/ETA, and
/// a confidence bar (the hook the AI Delay Prediction module feeds into).
class RouteCard extends StatelessWidget {
  final RouteOption route;
  const RouteCard({super.key, required this.route});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: AppColors.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(route.departureTime,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: route.status.color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20)),
                child: Text(route.status.label,
                    style: TextStyle(
                        color: route.status.color,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(route.mode,
              style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                  letterSpacing: 0.5)),
          Text(route.etaSummary,
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: route.confidence,
              minHeight: 6,
              backgroundColor: AppColors.divider,
              valueColor: AlwaysStoppedAnimation(route.status.color),
            ),
          ),
          const SizedBox(height: 4),
          Text('${(route.confidence * 100).round()}% confidence',
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
