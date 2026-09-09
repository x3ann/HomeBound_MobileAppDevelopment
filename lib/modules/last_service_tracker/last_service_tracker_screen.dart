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
/// api.data.gov.my, falling back to mock data automatically), then asks
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

class _LastServiceTrackerScreenState
    extends State<LastServiceTrackerScreen> {
  Timer? _timer;

  bool _loading = true;
  bool _locating = false;

  List<Stop> _stops = MockData.nearbyStops;

  TransitDataSource _source = TransitDataSource.mock;

  Duration _remaining = Duration.zero;

  String? _locationMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result =
    await TransitRepository.instance.getNearbyStops();

    if (!mounted) return;

    setState(() {
      _stops = result.stops;
      _source = result.source;
      _remaining = _nearestStop.timeToDeparture;
      _loading = false;
    });

    _startCountdown();

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

        setState(() {
          if (_remaining.inSeconds > 0) {
            _remaining -= const Duration(seconds: 1);
          } else {
            _timer?.cancel();
          }
        });
      },
    );
  }

  Future<void> _useCurrentLocation() async {
    setState(() {
      _locating = true;
      _locationMessage = null;
    });

    final location =
    await LocationService.instance.requestCurrentLocation();

    if (!mounted) return;

    if (location.status == LocationStatus.available) {
      setState(() {
        _stops = TransitRepository.instance.sortByDistance(
          _stops,
          location.position!,
        );

        _remaining = _nearestStop.timeToDeparture;

        _locationMessage =
        'Stops are ordered by distance from your location.';

        _locating = false;
      });

      _startCountdown();

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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
          color: AppColors.gold,
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
      onRefresh: () async {
        final result =
        await TransitRepository.instance.getNearbyStops(
          forceRefresh: true,
        );

        if (!mounted) return;

        setState(() {
          _stops = result.stops;
          _source = result.source;
          _remaining = _nearestStop.timeToDeparture;
        });

        _startCountdown();
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          20,
          16,
          20,
          24,
        ),
        children: [
          Row(
            mainAxisAlignment:
            MainAxisAlignment.spaceBetween,
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
            onPressed:
            _locating ? null : _useCurrentLocation,
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

          const Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Next Bus',
                  value: '11:52',
                  caption: 'Rapid KL 780',
                ),
              ),

              SizedBox(width: 12),

              Expanded(
                child: StatTile(
                  label: 'Delay Risk',
                  value: '68%',
                  caption: 'AI prediction',
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