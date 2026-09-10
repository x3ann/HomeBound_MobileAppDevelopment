import 'package:flutter/material.dart';

import '../../../shared/models/stop.dart';
import '../../../shared/theme/app_theme.dart';

class TransitTimetableSheet extends StatefulWidget {
  final List<Stop> stops;

  const TransitTimetableSheet({super.key, required this.stops});

  @override
  State<TransitTimetableSheet> createState() => _TransitTimetableSheetState();
}

class _TransitTimetableSheetState extends State<TransitTimetableSheet> {
  String _mode = 'All';
  String _line = 'All lines';
  String _query = '';

  List<String> get _modes {
    final values = <String>{};
    for (final stop in widget.stops) {
      values.addAll(stop.transportMode
          .split('/')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty && value != 'Rail'));
    }
    final sorted = values.toList()..sort();
    return ['All', ...sorted];
  }

  List<String> get _lines {
    final values = <String>{};
    for (final stop in widget.stops) {
      if (_mode != 'All' &&
          !stop.transportMode.toLowerCase().contains(_mode.toLowerCase())) {
        continue;
      }
      values.addAll(stop.routeLabel
          .split(' · ')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty));
    }
    final sorted = values.toList()..sort();
    return ['All lines', ...sorted];
  }

  List<Stop> get _visibleStops {
    final needle = _query.trim().toLowerCase();
    return widget.stops.where((stop) {
      final modeMatches = _mode == 'All' ||
          stop.transportMode.toLowerCase().contains(_mode.toLowerCase());
      final lineMatches = _line == 'All lines' ||
          stop.routeLabel.toLowerCase().contains(_line.toLowerCase());
      final textMatches = needle.isEmpty ||
          stop.name.toLowerCase().contains(needle) ||
          stop.routeLabel.toLowerCase().contains(needle);
      return modeMatches && lineMatches && textMatches;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleStops;
    return SafeArea(
      child: Container(
        height: MediaQuery.sizeOf(context).height * .9,
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
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Public transport timetable',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.w900)),
                        SizedBox(height: 3),
                        Text('Official scheduled first/last-service data',
                            style: TextStyle(
                                fontSize: 11, color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  hintText: 'Search station, stop, route, or line',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _mode,
                      isExpanded: true,
                      decoration:
                          const InputDecoration(labelText: 'Transport type'),
                      items: _modes
                          .map((mode) => DropdownMenuItem(
                                value: mode,
                                child:
                                    Text(mode, overflow: TextOverflow.ellipsis),
                              ))
                          .toList(),
                      onChanged: (value) => setState(() {
                        _mode = value ?? 'All';
                        _line = 'All lines';
                      }),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('$_mode|$_line'),
                      initialValue: _line,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Line'),
                      items: _lines
                          .map((line) => DropdownMenuItem(
                                value: line,
                                child:
                                    Text(line, overflow: TextOverflow.ellipsis),
                              ))
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _line = value ?? 'All lines'),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('${visible.length} matching stops',
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary)),
              ),
            ),
            Expanded(
              child: visible.isEmpty
                  ? const Center(
                      child: Text('No timetable entries match these filters.'))
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                      itemCount: visible.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) =>
                          _TimetableTile(stop: visible[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimetableTile extends StatelessWidget {
  final Stop stop;

  const _TimetableTile({required this.stop});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          children: [
            Icon(stop.transportMode == 'Bus'
                ? Icons.directions_bus_rounded
                : Icons.train_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(stop.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 3),
                  Text(
                    stop.routeLabel.isEmpty
                        ? stop.transportMode
                        : '${stop.transportMode} · ${stop.routeLabel}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    stop.isOperating
                        ? 'Next: ${stop.formattedCountdown}'
                        : 'Service currently closed',
                    style: TextStyle(
                      fontSize: 11,
                      color: stop.isOperating
                          ? AppColors.success
                          : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text('LAST SERVICE',
                    style:
                        TextStyle(fontSize: 9, color: AppColors.textSecondary)),
                const SizedBox(height: 3),
                Text(stop.lastService,
                    style: const TextStyle(
                        color: AppColors.gold, fontWeight: FontWeight.w900)),
              ],
            ),
          ],
        ),
      );
}
