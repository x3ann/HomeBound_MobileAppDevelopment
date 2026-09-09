import 'package:flutter/material.dart';
import '../shared/theme/app_theme.dart';

/// Stand-in screen for modules owned by a teammate, so the shared bottom
/// nav is fully wired up even before their screens land in the repo.
class PlaceholderModuleScreen extends StatelessWidget {
  final String title;
  final String owner;
  final IconData icon;
  final Color accent;

  const PlaceholderModuleScreen({
    super.key,
    required this.title,
    required this.owner,
    required this.icon,
    this.accent = AppColors.gold,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: accent.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            Text(title,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text('Owned by $owner · in progress',
                style: const TextStyle(color: AppColors.textSecondary),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
