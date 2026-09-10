import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/gtfs_service.dart';
import '../../../shared/models/route_model.dart';
import '../../../shared/theme/app_theme.dart';

class RouteCard extends StatelessWidget {
  final RouteOption route;
  final int optionIndex;
  final VoidCallback onTap;

  const RouteCard({
    super.key,
    required this.route,
    required this.optionIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = switch (optionIndex) {
      0 => AppColors.gold,
      1 => Colors.lightBlueAccent,
      _ => Colors.purpleAccent,
    };
    final label = switch (optionIndex) {
      0 => 'FASTEST',
      1 => route.mode.toLowerCase().contains('bus')
          ? 'BEST BUS OPTION'
          : 'BEST RAIL OPTION',
      _ => 'ALTERNATIVE',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: accent.withValues(alpha: .55)),
            ),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(_modeIcon(route.mode), color: accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(label,
                              style: TextStyle(
                                  color: accent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: .8)),
                          const Spacer(),
                          Text('${route.totalMinutes} min',
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w900)),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(route.mode,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text(
                        '${route.departureTime} → ${route.arrivalTime} · '
                        '${route.transferCount} transfer${route.transferCount == 1 ? '' : 's'}',
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _modeIcon(String mode) {
    final text = mode.toLowerCase();
    if (text.contains('bus')) return Icons.directions_bus_rounded;
    if (text.contains('walk')) return Icons.directions_walk_rounded;
    return Icons.train_rounded;
  }
}

class RouteDetailsSheet extends StatefulWidget {
  final RouteOption route;

  const RouteDetailsSheet({super.key, required this.route});

  @override
  State<RouteDetailsSheet> createState() => _RouteDetailsSheetState();
}

class _RouteDetailsSheetState extends State<RouteDetailsSheet> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  double get _progress {
    final route = widget.route;
    if (route.departureServiceSeconds <= 0 ||
        route.arrivalServiceSeconds <= route.departureServiceSeconds) {
      return 0;
    }
    final now = GtfsService.secondsIntoServiceDay(DateTime.now());
    return ((now - route.departureServiceSeconds) /
            (route.arrivalServiceSeconds - route.departureServiceSeconds))
        .clamp(0.0, 1.0);
  }

  String get _progressLabel {
    final progress = _progress;
    if (progress <= 0) {
      return 'Upcoming · departs ${widget.route.departureTime}';
    }
    if (progress >= 1) return 'Scheduled journey complete';
    final remaining = (widget.route.totalMinutes * (1 - progress)).ceil();
    return 'In progress · about $remaining min remaining';
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.route.steps;
    final progress = _progress;
    final activeIndex = steps.isEmpty
        ? 0
        : (progress * steps.length).floor().clamp(0, steps.length - 1);
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .86,
        ),
        decoration: const BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
              child: Row(
                children: [
                  const Icon(Icons.route_rounded, color: AppColors.gold),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('Journey details',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w900)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 26),
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.route.mode,
                            style:
                                const TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        Text(
                          '${widget.route.departureTime} → ${widget.route.arrivalTime}',
                          style: const TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${widget.route.totalMinutes} min total · '
                          '${widget.route.transferCount} transfer${widget.route.transferCount == 1 ? '' : 's'}',
                          style:
                              const TextStyle(color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 16),
                        LinearProgressIndicator(
                          value: progress,
                          minHeight: 7,
                          borderRadius: BorderRadius.circular(10),
                          backgroundColor: AppColors.surfaceAlt,
                          color: AppColors.gold,
                        ),
                        const SizedBox(height: 7),
                        Text(_progressLabel,
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text('How to get there',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 12),
                  for (var index = 0; index < steps.length; index++)
                    _TimelineStep(
                      text: steps[index],
                      isLast: index == steps.length - 1,
                      state: progress >= 1 || index < activeIndex
                          ? _StepState.complete
                          : index == activeIndex && progress > 0
                              ? _StepState.current
                              : _StepState.upcoming,
                    ),
                  const SizedBox(height: 8),
                  Text(
                    widget.route.mode.toLowerCase().contains('bus')
                        ? 'Bus times use the official published schedule. Live traffic may change the actual arrival; follow operator updates.'
                        : 'Rail times use the official published timetable. Follow station signs and operator announcements during disruptions.',
                    style: const TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _StepState { complete, current, upcoming }

class _TimelineStep extends StatelessWidget {
  final String text;
  final bool isLast;
  final _StepState state;

  const _TimelineStep({
    required this.text,
    required this.isLast,
    required this.state,
  });

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      _StepState.complete => AppColors.success,
      _StepState.current => AppColors.gold,
      _StepState.upcoming => AppColors.textSecondary,
    };
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: .18),
                    border: Border.all(color: color, width: 2),
                  ),
                  child: Icon(
                    state == _StepState.complete
                        ? Icons.check_rounded
                        : state == _StepState.current
                            ? Icons.navigation_rounded
                            : Icons.circle,
                    size: state == _StepState.upcoming ? 7 : 13,
                    color: color,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(width: 2, color: AppColors.divider),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 22),
              child: Text(text,
                  style: TextStyle(
                    fontWeight: state == _StepState.current
                        ? FontWeight.w800
                        : FontWeight.w500,
                    color: state == _StepState.upcoming
                        ? AppColors.textSecondary
                        : AppColors.textPrimary,
                  )),
            ),
          ),
        ],
      ),
    );
  }
}
