import 'package:flutter/material.dart';
import '../../../shared/theme/app_theme.dart';

/// Small stat card used for schedule-derived service summaries.
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String caption;

  const StatTile({
    super.key,
    required this.label,
    required this.value,
    required this.caption,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppColors.gold)),
          Text(caption,
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
