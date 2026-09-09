import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../services/bus_arrival_service.dart';
import '../../services/realtime_transit_service.dart';
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
  Timer? _busTimer;

  bool _loading = true;
  bool _locating = false;
  bool _refreshingExpired = false;
  bool _loadingBuses = false;

  List<Stop> _stops = const [];
  List<Stop> _railStops = const [];
  List<Stop> _busStops = const [];
  List<String> _nearbyBusRoutes = const [];
  LatLng? _userLocation;

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
      _railStops = result.stops;
      _stops = result.stops;
      _source = result.source;
      _remaining =
          _stops.isEmpty ? Duration.zero : _featuredStop.timeToDeparture;
      _loading = false;
    });

    if (_stops.isNotEmpty && _canCountdown) _startCountdown();

    // Ask for location automatically once stops are loaded, so the
    // "nearest stop" is based on where the person actually is, not just
    // the app's default ordering.
    _useCurrentLocation();
    _busTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        final location = _userLocation;
        if (location != null) _loadNearbyBuses(location);
      },
    );
  }

  void _startCountdown() {
    _timer?.cancel();

    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;

        if (_remaining.inSeconds > 0) {
          setState(() {
            _remaining -= const Duration(seconds: 1);
            _stops = _stops
                .map((stop) => stop.hasDepartureData &&
                        stop.isOperating &&
                        stop.timeToDeparture > Duration.zero
                    ? stop.copyWith(
                        timeToDeparture:
                            stop.timeToDeparture - const Duration(seconds: 1))
                    : stop)
                .toList();
          });
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
      _railStops = result.stops;
      _combineNearbyStops();
      _source = result.source;
      _remaining =
          _stops.isEmpty ? Duration.zero : _featuredStop.timeToDeparture;
    });
    _refreshingExpired = false;
    if (_stops.isNotEmpty) {
      if (_stops.isNotEmpty && _canCountdown) _startCountdown();
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
      final position = location.position!;
      _userLocation = position;
      _railStops = TransitRepository.instance.sortByDistance(
        _railStops,
        position,
      );
      setState(() {
        _combineNearbyStops();
        _remaining =
            _stops.isEmpty ? Duration.zero : _featuredStop.timeToDeparture;

        _locationMessage =
            'Showing rail stations and bus stops within 2 km of your location.';

        _locating = false;
      });

      if (_stops.isNotEmpty && _canCountdown) _startCountdown();

      if (_stops.isNotEmpty && _featuredStop.transportMode != 'Bus') {
        final estimated = await TransitRepository.instance
            .withExperimentalEstimate(_featuredStop);
        if (mounted && estimated.gtfsStopId == _featuredStop.gtfsStopId) {
          setState(() {
            final index = _stops.indexOf(_featuredStop);
            if (index >= 0) _stops[index] = estimated;
          });
        }
      }

      await _loadNearbyBuses(position);

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

  Future<void> _loadNearbyBuses(LatLng location) async {
    if (_loadingBuses) return;
    _loadingBuses = true;
    const categories = ['rapid-bus-kl', 'rapid-bus-mrtfeeder'];
    final busStops = <Stop>[];
    final liveStops = <Stop>[];
    final nearbyRoutes = <String, double>{};
    const distance = Distance();
    try {
      for (final category in categories) {
        try {
          busStops.addAll(await BusArrivalService.instance.nearbyStops(
            userLocation: location,
            radiusMeters: 2000,
            category: category,
          ));
        } catch (_) {
          // Keep results from other feeds when one static feed is unavailable.
        }
        try {
          final vehicles = await RealtimeTransitService.instance
              .fetchVehicles(category: category);
          for (final vehicle in vehicles) {
            final meters = distance.as(
              LengthUnit.Meter,
              location,
              vehicle.position,
            );
            if (meters <= 2000) {
              final previous = nearbyRoutes[vehicle.routeLabel];
              if (previous == null || meters < previous) {
                nearbyRoutes[vehicle.routeLabel] = meters;
              }
            }
          }
          final arrivals = await BusArrivalService.instance.estimateArrivals(
            vehicles: vehicles,
            userLocation: location,
            category: category,
          );
          liveStops.addAll(arrivals.map((arrival) => arrival.stop));
        } catch (_) {
          // Static bus stops remain useful without a live vehicle match.
        }
      }
      final unique = <String, Stop>{};
      for (final stop in liveStops) {
        unique[_stopKey(stop)] = stop;
      }
      for (final stop in busStops) {
        unique.putIfAbsent(_stopKey(stop), () => stop);
      }
      final sortedRoutes = nearbyRoutes.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      if (!mounted) return;
      setState(() {
        _busStops = unique.values.toList();
        _nearbyBusRoutes =
            sortedRoutes.take(8).map((entry) => entry.key).toList();
        _combineNearbyStops();
        _remaining =
            _stops.isEmpty ? Duration.zero : _featuredStop.timeToDeparture;
      });
      if (_stops.isNotEmpty && _canCountdown) _startCountdown();
    } finally {
      _loadingBuses = false;
    }
  }

  void _combineNearbyStops() {
    final location = _userLocation;
    if (location == null) {
      _stops = _railStops;
      return;
    }
    final rail = _railStops
        .where((stop) => (stop.distanceMeters ?? double.infinity) <= 2000);
    final combined = [...rail, ..._busStops]..sort((a, b) =>
        (a.distanceMeters ?? double.infinity)
            .compareTo(b.distanceMeters ?? double.infinity));
    _stops = combined.take(12).toList();
  }

  String _stopKey(Stop stop) =>
      '${stop.transportMode}|${stop.gtfsStopId ?? stop.name}|${stop.position.latitude.toStringAsFixed(5)}';

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
    _busTimer?.cancel();
    super.dispose();
  }

  // The nearest stop is always index 0 — TransitRepository.sortByDistance
  // sorts ascending by distance, so the first element is the closest.
  Stop get _featuredStop => _stops.firstWhere(
        (stop) => stop.hasDepartureData && stop.isOperating,
        orElse: () => _stops.first,
      );

  bool get _canCountdown =>
      _featuredStop.isOperating &&
      _featuredStop.hasDepartureData &&
      _remaining > Duration.zero;

  ServiceUrgency get _urgency {
    if (!_featuredStop.isOperating) return ServiceUrgency.critical;
    if (_remaining.inMinutes <= 5) {
      return ServiceUrgency.critical;
    }

    if (_remaining.inMinutes <= 20) {
      return ServiceUrgency.closingSoon;
    }

    return ServiceUrgency.onTime;
  }

  String _formatRemaining(Duration duration) {
    if (!_featuredStop.isOperating) return 'Out of service';
    if (!_featuredStop.hasDepartureData) return 'ETA unavailable';
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
            Text(
                _userLocation == null
                    ? 'Official transit data is unavailable'
                    : 'No public transport stops found within 2 km',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
                _userLocation == null
                    ? 'Check your connection and pull down to try again.'
                    : 'Refresh your location or open the map to search farther away.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 16),
            DataSourceBadge(source: _source),
          ],
        ),
      );
    }

    final criticalCount = _stops
        .where(
          (s) => s.isOperating && s.urgency == ServiceUrgency.critical,
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
            stop: _featuredStop,
            remaining: _remaining,
            urgency: _urgency,
          ),
          const SizedBox(height: 16),
          LiveMapPreviewCard(
            nearbyCount: _stops.length,
            criticalCount: criticalCount,
            onTap: widget.onOpenLiveMap,
          ),
          if (_nearbyBusRoutes.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('Nearby Bus Routes',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _nearbyBusRoutes
                  .map((route) => Chip(
                        avatar:
                            const Icon(Icons.directions_bus_rounded, size: 16),
                        label: Text(route),
                      ))
                  .toList(),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Next departure',
                  value: _formatRemaining(_remaining),
                  caption: _featuredStop.name,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: StatTile(
                  label: 'Last service',
                  value: _featuredStop.lastService,
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
