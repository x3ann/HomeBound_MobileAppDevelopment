import 'package:flutter/material.dart';
import '../../../shared/theme/app_theme.dart';

/// Small pill showing departure proximity (SCHEDULED / ARRIVING SOON / DUE SOON).
/// Used by the Last Service Tracker countdown card.
class StatusChip extends StatelessWidget {
  final ServiceUrgency urgency;
  const StatusChip({super.key, required this.urgency});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: urgency.color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        urgency.label,
        style: TextStyle(
            color: urgency.color, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }
}
