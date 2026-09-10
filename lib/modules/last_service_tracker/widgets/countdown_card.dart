import 'package:flutter/material.dart';
import '../../../shared/models/stop.dart';
import '../../../shared/theme/app_theme.dart';

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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('NEAREST STOP',
                        style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                            letterSpacing: 1)),
                    const SizedBox(height: 2),
                    Text(stop.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                    Text(stop.platform,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: urgency.color.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  stop.serviceStatusLabel,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: urgency.color,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
              stop.isOperating
                  ? 'TIME TO NEXT SCHEDULED DEPARTURE'
                  : 'CURRENT SERVICE STATUS',
              style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                  letterSpacing: 1)),
          if (!stop.isOperating)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('OUT OF SERVICE',
                  style: TextStyle(
                      color: AppColors.critical,
                      fontSize: 30,
                      fontWeight: FontWeight.w900)),
            )
          else if (!stop.hasDepartureData)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('ETA UNAVAILABLE',
                  style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800)),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(_mm,
                    style: const TextStyle(
                        fontSize: 44, fontWeight: FontWeight.w800)),
                const Text('m ',
                    style: TextStyle(
                        fontSize: 18, color: AppColors.textSecondary)),
                Text(_ss,
                    style: const TextStyle(
                        fontSize: 44, fontWeight: FontWeight.w800)),
                const Text('s',
                    style: TextStyle(
                        fontSize: 18, color: AppColors.textSecondary)),
              ],
            ),
          const SizedBox(height: 4),
          Text(
            stop.transportMode == 'Bus'
                ? (stop.hasDepartureData
                    ? 'Estimated from the latest live bus position'
                    : 'Official bus stop · live ETA unavailable')
                : (stop.liveRailEstimate == null
                    ? 'Live rail estimate unavailable · showing official schedule'
                    : 'Experimental live estimate: ${stop.liveRailEstimate}'),
            style:
                const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            stop.transportMode == 'Bus'
                ? (stop.routeLabel.isEmpty
                    ? 'Bus route information unavailable'
                    : 'Routes: ${stop.routeLabel}')
                : 'Last scheduled service: ${stop.lastService}',
            style:
                const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
