import 'package:flutter/material.dart';
import '../../../shared/models/stop.dart';
import '../../../shared/theme/app_theme.dart';
import 'status_chip.dart';

/// Big countdown card: nearest stop name/platform, status chip, and the
/// live mm:ss countdown to the next scheduled departure. This is the single widget to
/// edit if you want to change how the countdown itself looks or behaves.
class CountdownCard extends StatelessWidget {
  final Stop stop;
  final Duration remaining;
  final ServiceUrgency urgency;

  const CountdownCard({
    super.key,
    required this.stop,
    required this.remaining,
    required this.urgency,
  });

  String get _mm => remaining.inMinutes.remainder(60).toString();
  String get _ss =>
      remaining.inSeconds.remainder(60).toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: urgency.color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('NEAREST STOP',
                      style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                          letterSpacing: 1)),
                  const SizedBox(height: 2),
                  Text(stop.name,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                  Text(stop.platform,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
              StatusChip(urgency: urgency),
            ],
          ),
          const SizedBox(height: 18),
          const Text('TIME TO NEXT SCHEDULED DEPARTURE',
              style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                  letterSpacing: 1)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(_mm,
                  style: const TextStyle(
                      fontSize: 44, fontWeight: FontWeight.w800)),
              const Text('m ',
                  style:
                      TextStyle(fontSize: 18, color: AppColors.textSecondary)),
              Text(_ss,
                  style: const TextStyle(
                      fontSize: 44, fontWeight: FontWeight.w800)),
              const Text('s',
                  style:
                      TextStyle(fontSize: 18, color: AppColors.textSecondary)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            stop.liveRailEstimate == null
                ? 'Live rail estimate unavailable · showing official schedule'
                : 'Experimental live estimate: ${stop.liveRailEstimate}',
            style:
                const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            'Last scheduled service: ${stop.lastService} tonight',
            style:
                const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
