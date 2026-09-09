import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/transit_repository.dart';
import '../../services/location_service.dart';
import '../../shared/models/stop.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/data_source_badge.dart';
import '../../screens/profile_screen.dart';

import 'widgets/countdown_card.dart';
import 'widgets/live_map_preview_card.dart';
import 'widgets/stat_tile.dart';
import 'widgets/stop_tile.dart';

/// MODULE: Last Service Tracker (Chung Wei Xean)
/// Loads stops from TransitRepository (live GTFS feed from
/// api.data.gov.my), then asks
/// for the device's location automatically on open so nearby stops and
/// the "nearest stop" countdown are correct from the first frame.
class LastServiceTrackerScreen extends StatefulWidget {
  final VoidCallback? onOpenLiveMap;

  const LastServiceTrackerScreen({
    super.key,
    this.onOpenLiveMap,
  });

  @override
  State<LastServiceTrackerScreen> createState() =>
      _LastServiceTrackerScreenState();
}

class _LastServiceTrackerScreenState extends State<LastServiceTrackerScreen> {
  Timer? _timer;

  bool _loading = true;
  bool _locating = false;
  bool _refreshingExpired = false;

  List<Stop> _stops = const [];

  TransitDataSource _source = TransitDataSource.unavailable;

  Duration _remaining = Duration.zero;

  String? _locationMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await TransitRepository.instance.getNearbyStops();

    if (!mounted) return;

    setState(() {
      _stops = result.stops;
      _source = result.source;
      _remaining =
          _stops.isEmpty ? Duration.zero : _nearestStop.timeToDeparture;
      _loading = false;
    });

    if (_stops.isNotEmpty && _remaining > Duration.zero) _startCountdown();

    // Ask for location automatically once stops are loaded, so the
    // "nearest stop" is based on where the person actually is, not just
    // the app's default ordering.
    _useCurrentLocation();
  }

  void _startCountdown() {
    _timer?.cancel();

    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;

        if (_remaining.inSeconds > 0) {
          setState(() => _remaining -= const Duration(seconds: 1));
        } else {
          _timer?.cancel();
          _refreshExpiredSchedule();
        }
      },
    );
  }

  Future<void> _refreshExpiredSchedule() async {
    if (_refreshingExpired) return;
    _refreshingExpired = true;
    final result = await TransitRepository.instance.getNearbyStops(
      forceRefresh: true,
    );
    if (!mounted) return;
    setState(() {
      _stops = result.stops;
      _source = result.source;
      _remaining =
          _stops.isEmpty ? Duration.zero : _nearestStop.timeToDeparture;
    });
    _refreshingExpired = false;
    if (_stops.isNotEmpty) {
      if (_remaining > Duration.zero) _startCountdown();
      await _useCurrentLocation();
    }
  }

  Future<void> _useCurrentLocation() async {
    setState(() {
      _locating = true;
      _locationMessage = null;
    });

    final location = await LocationService.instance.requestCurrentLocation();

    if (!mounted) return;

    if (location.status == LocationStatus.available) {
      final ordered = TransitRepository.instance.sortByDistance(
        _stops,
        location.position!,
      );
      final withinEightKm = ordered
          .where((stop) => (stop.distanceMeters ?? double.infinity) <= 8000)
          .take(8)
          .toList();
      setState(() {
        _stops =
            withinEightKm.isNotEmpty ? withinEightKm : ordered.take(8).toList();
        _remaining =
            _stops.isEmpty ? Duration.zero : _nearestStop.timeToDeparture;

        _locationMessage = 'Stops are ordered by distance from your location.';

        _locating = false;
      });

      if (_remaining > Duration.zero) _startCountdown();

      if (_stops.isNotEmpty) {
        final estimated = await TransitRepository.instance
            .withExperimentalEstimate(_nearestStop);
        if (mounted) setState(() => _stops[0] = estimated);
      }

      return;
    }

    const messages = {
      LocationStatus.disabled:
          'Turn on Location Services to find nearby stops.',
      LocationStatus.denied:
          'Location permission was not granted. You can try again anytime.',
      LocationStatus.deniedForever:
          'Location permission is blocked. Enable it in your phone settings.',
      LocationStatus.unavailable:
          'We could not get your location. Please try again.',
    };

    setState(() {
      _locationMessage = messages[location.status];
      _locating = false;
    });
  }

  void _openProfile() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ProfileScreen(),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // The nearest stop is always index 0 — TransitRepository.sortByDistance
  // sorts ascending by distance, so the first element is the closest.
  Stop get _nearestStop => _stops.first;

  ServiceUrgency get _urgency {
    if (_remaining.inMinutes <= 5) {
      return ServiceUrgency.critical;
    }

    if (_remaining.inMinutes <= 20) {
      return ServiceUrgency.closingSoon;
    }

    return ServiceUrgency.onTime;
  }

  String _formatRemaining(Duration duration) {
    if (duration <= Duration.zero) return 'No more today';
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return hours > 0
        ? '${hours}h ${minutes}m'
        : '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
          color: AppColors.gold,
        ),
      );
    }

    if (_stops.isEmpty) {
      return RefreshIndicator(
        color: AppColors.gold,
        onRefresh: _refreshExpiredSchedule,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 80),
            const Icon(Icons.cloud_off_rounded,
                size: 48, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            const Text('Official transit data is unavailable',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('Check your connection and pull down to try again.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 16),
            DataSourceBadge(source: _source),
          ],
        ),
      );
    }

    final criticalCount = _stops
        .where(
          (s) => s.urgency == ServiceUrgency.critical,
        )
        .length;

    return RefreshIndicator(
      color: AppColors.gold,
      backgroundColor: AppColors.surface,
      onRefresh: _refreshExpiredSchedule,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          20,
          16,
          20,
          24,
        ),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Homebound',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _openProfile,
                  borderRadius: BorderRadius.circular(40),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: CircleAvatar(
                      radius: 18,
                      backgroundColor: AppColors.surface,
                      child: Icon(
                        Icons.person_rounded,
                        color: AppColors.gold,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: DataSourceBadge(
              source: _source,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _locating ? null : _useCurrentLocation,
            icon: _locating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(
                    Icons.my_location_rounded,
                  ),
            label: Text(
              _locating
                  ? 'Finding your location…'
                  : 'Refresh my current location',
            ),
          ),
          if (_locationMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _locationMessage!,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 16),
          CountdownCard(
            stop: _nearestStop,
            remaining: _remaining,
            urgency: _urgency,
          ),
          const SizedBox(height: 16),
          LiveMapPreviewCard(
            nearbyCount: _stops.length,
            criticalCount: criticalCount,
            onTap: widget.onOpenLiveMap,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Next departure',
                  value: _formatRemaining(_remaining),
                  caption: _nearestStop.name,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: StatTile(
                  label: 'Last service',
                  value: _nearestStop.lastService,
                  caption: 'Official timetable',
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text(
            'Nearby Stops',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          ..._stops.map(
            (s) => StopTile(
              stop: s,
            ),
          ),
        ],
      ),
    );
  }
}
