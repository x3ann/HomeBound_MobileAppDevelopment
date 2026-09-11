import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../services/bus_arrival_service.dart';
import '../../services/realtime_transit_service.dart';
import '../../services/transit_repository.dart';
import '../../services/location_service.dart';
import '../../shared/models/stop.dart';
import '../../shared/models/bus_arrival_estimate.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/data_source_badge.dart';
import '../../screens/profile_screen.dart';

import 'widgets/countdown_card.dart';
import 'widgets/live_map_preview_card.dart';
import 'widgets/stat_tile.dart';
import 'widgets/stop_tile.dart';
import 'widgets/transit_timetable_sheet.dart';

/// MODULE: Last Service Tracker (Chung Wei Xean)
/// Loads stops from TransitRepository (live GTFS feed from
/// api.data.gov.my), then asks
/// for the device's location automatically on open so nearby stops and
/// the "nearest stop" countdown are correct from the first frame.
class LastServiceTrackerScreen extends StatefulWidget {
  final VoidCallback? onOpenLiveMap;
  final ValueChanged<String>? onOpenBusRoute;

  const LastServiceTrackerScreen({
    super.key,
    this.onOpenLiveMap,
    this.onOpenBusRoute,
  });

  @override
  State<LastServiceTrackerScreen> createState() =>
      _LastServiceTrackerScreenState();
}

class _LastServiceTrackerScreenState extends State<LastServiceTrackerScreen>
    with WidgetsBindingObserver {
  Timer? _timer;
  Timer? _busTimer;
  Timer? _clockTimer;
  DateTime _lastClockReading = DateTime.now();

  bool _loading = true;
  bool _locating = false;
  bool _refreshingExpired = false;
  bool _loadingBuses = false;

  List<Stop> _stops = const [];
  List<Stop> _railStops = const [];
  List<Stop> _busStops = const [];
  List<String> _nearbyBusRoutes = const [];
  Map<String, BusArrivalEstimate> _nearbyBusEtas = const {};
  final Map<String, String> _directionByStop = {};
  LatLng? _userLocation;

  TransitDataSource _source = TransitDataSource.unavailable;

  Duration _remaining = Duration.zero;

  String? _locationMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _clockTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _checkDeviceClock());
  }

  void _checkDeviceClock() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastClockReading).inSeconds;
    _lastClockReading = now;
    if (elapsed < 0 || elapsed > 7) {
      _refreshExpiredSchedule();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _lastClockReading = DateTime.now();
      _refreshExpiredSchedule();
    }
  }

  Future<void> _load() async {
    final result = await TransitRepository.instance.getNearbyStops();

    if (!mounted) return;

    setState(() {
      _railStops = _applyDirectionSelections(result.stops);
      _stops = _railStops;
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
    // Location and bus data refresh independently. Do not restart the
    // one-second clock when those background refreshes finish.
    if (_timer?.isActive ?? false) return;

    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;

        if (_remaining.inSeconds > 0) {
          setState(() {
            _remaining -= const Duration(seconds: 1);
            _railStops = _tickCountdowns(_railStops);
            _busStops = _tickCountdowns(_busStops);
            _stops = _tickCountdowns(_stops);
          });
        } else {
          _timer?.cancel();
          _refreshExpiredSchedule();
        }
      },
    );
  }

  List<Stop> _tickCountdowns(List<Stop> stops) => stops.map((stop) {
        if (stop.directionOptions.isNotEmpty) {
          final options = stop.directionOptions
              .map((option) =>
                  option.isOperating && option.timeToDeparture > Duration.zero
                      ? TransitDirectionOption(
                          key: option.key,
                          destination: option.destination,
                          routeLabel: option.routeLabel,
                          transportMode: option.transportMode,
                          timeToDeparture: option.timeToDeparture -
                              const Duration(seconds: 1),
                          urgency: option.urgency,
                          lastService: option.lastService,
                          hasDepartureData: option.hasDepartureData,
                          isOperating: option.isOperating,
                        )
                      : option)
              .toList();
          final updated = stop.copyWith(directionOptions: options);
          return updated
              .withDirection(updated.selectedDirectionKey ?? options.first.key);
        }
        return stop.hasDepartureData &&
                stop.isOperating &&
                stop.timeToDeparture > Duration.zero
            ? stop.copyWith(
                timeToDeparture:
                    stop.timeToDeparture - const Duration(seconds: 1),
              )
            : stop;
      }).toList();

  Future<void> _refreshExpiredSchedule() async {
    if (_refreshingExpired) return;
    _refreshingExpired = true;
    try {
      BusArrivalService.instance.clearCache();
      final result = await TransitRepository.instance.getNearbyStops(
        forceRefresh: true,
      );
      if (!mounted) return;
      final location = _userLocation;
      final selectedStops = _applyDirectionSelections(result.stops);
      final refreshedRailStops = location == null
          ? selectedStops
          : TransitRepository.instance.sortByDistance(
              selectedStops,
              location,
            );
      setState(() {
        _railStops = refreshedRailStops;
        _combineNearbyStops();
        _source = result.source;
        _remaining =
            _stops.isEmpty ? Duration.zero : _featuredStop.timeToDeparture;
      });
      if (_stops.isNotEmpty && _canCountdown) _startCountdown();
      if (location != null) await _loadNearbyBuses(location);
    } finally {
      _refreshingExpired = false;
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
    final routeEtas = <String, BusArrivalEstimate>{};
    const distance = Distance();
    try {
      for (final category in categories) {
        try {
          final categoryStops = await BusArrivalService.instance.nearbyStops(
            userLocation: location,
            radiusMeters: 2000,
            category: category,
          );
          busStops.addAll(categoryStops);
          for (final stop in categoryStops.where((stop) =>
              stop.routeLabel.isNotEmpty && stop.distanceMeters != null)) {
            for (final label in stop.routeLabel.split(' · ')) {
              final previous = nearbyRoutes[label];
              if (previous == null || stop.distanceMeters! < previous) {
                nearbyRoutes[label] = stop.distanceMeters!;
              }
            }
          }
          final scheduled =
              await BusArrivalService.instance.nearbyScheduledArrivals(
            userLocation: location,
            radiusMeters: 2000,
            category: category,
          );
          for (final arrival in scheduled) {
            final key = _routeKey(arrival.routeLabel);
            final current = routeEtas[key];
            if (current == null ||
                (!current.stop.isLiveEstimate && arrival.eta < current.eta)) {
              routeEtas[key] = arrival;
            }
          }
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
          for (final arrival in arrivals) {
            final key = _routeKey(arrival.routeLabel);
            final current = routeEtas[key];
            if (current == null ||
                !current.stop.isLiveEstimate ||
                arrival.eta < current.eta) {
              routeEtas[key] = arrival;
            }
          }
        } catch (_) {
          // Static bus stops remain useful without a live vehicle match.
        }
      }
      final unique = <String, Stop>{};
      for (final stop in liveStops) {
        final key = _stopKey(stop);
        final current = unique[key];
        if (current == null || stop.timeToDeparture < current.timeToDeparture) {
          unique[key] = _mergeDirectionOptions(stop, current);
        } else {
          unique[key] = _mergeDirectionOptions(current, stop);
        }
      }
      for (final stop in busStops) {
        final key = _stopKey(stop);
        unique[key] = _mergeDirectionOptions(unique[key] ?? stop, stop);
      }
      final sortedRoutes = nearbyRoutes.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      if (!mounted) return;
      setState(() {
        _busStops = unique.values.toList();
        _nearbyBusRoutes =
            sortedRoutes.take(8).map((entry) => entry.key).toList();
        _nearbyBusEtas = routeEtas;
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

  Stop _mergeDirectionOptions(Stop primary, Stop? other) {
    if (other == null) return primary;
    final options = <String, TransitDirectionOption>{
      for (final option in primary.directionOptions) option.key: option,
      for (final option in other.directionOptions) option.key: option,
    }.values.toList()
      ..sort((a, b) => a.timeToDeparture.compareTo(b.timeToDeparture));
    if (options.isEmpty) return primary;
    final selectedKey = primary.selectedDirectionKey ?? options.first.key;
    return primary
        .copyWith(
          directionOptions: options,
          selectedDirectionKey: selectedKey,
        )
        .withDirection(selectedKey);
  }

  List<Stop> _applyDirectionSelections(List<Stop> stops) => stops.map((stop) {
        final id = stop.gtfsStopId;
        final key = id == null ? null : _directionByStop[id];
        return key == null ? stop : stop.withDirection(key);
      }).toList();

  void _selectFeaturedDirection(String key) {
    final id = _featuredStop.gtfsStopId;
    if (id == null) return;
    _directionByStop[id] = key;
    Stop update(Stop stop) =>
        stop.gtfsStopId == id ? stop.withDirection(key) : stop;
    setState(() {
      _railStops = _railStops.map(update).toList();
      _busStops = _busStops.map(update).toList();
      _combineNearbyStops();
      _remaining = _featuredStop.timeToDeparture;
    });
    if (_canCountdown) _startCountdown();
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

  Future<List<Stop>> _loadFullTimetable() async {
    final groups = await Future.wait<List<Stop>>([
      TransitRepository.instance.getRailTimetableEntries(),
      BusArrivalService.instance
          .scheduledStops(category: 'rapid-bus-kl')
          .catchError((_) => <Stop>[]),
      BusArrivalService.instance
          .scheduledStops(category: 'rapid-bus-mrtfeeder')
          .catchError((_) => <Stop>[]),
    ]);
    final unique = <String, Stop>{};
    for (final stop in groups.expand((group) => group)) {
      unique.putIfAbsent(
        '${stop.transportMode}|${stop.gtfsStopId ?? stop.name}|${stop.routeLabel}',
        () => stop,
      );
    }
    final stops = unique.values.toList()
      ..sort((a, b) {
        final byMode = a.transportMode.compareTo(b.transportMode);
        return byMode != 0 ? byMode : a.name.compareTo(b.name);
      });
    return stops;
  }

  void _openFullTimetable() {
    final timetable = _loadFullTimetable();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => FutureBuilder<List<Stop>>(
        future: timetable,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return TransitTimetableSheet(stops: snapshot.data!);
          }
          final message = snapshot.hasError
              ? 'The official timetable could not be loaded. Close this panel and try again.'
              : 'Loading rail, bus, and feeder schedules…';
          return SafeArea(
            child: Container(
              height: MediaQuery.sizeOf(context).height * .45,
              decoration: const BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!snapshot.hasError) const CircularProgressIndicator(),
                      if (!snapshot.hasError) const SizedBox(height: 18),
                      Text(message, textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _busTimer?.cancel();
    _clockTimer?.cancel();
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
    if (_remaining <= const Duration(minutes: 5)) {
      return ServiceUrgency.critical;
    }

    if (_remaining <= const Duration(minutes: 20)) {
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
          if (_featuredStop.hasDirectionChoices) ...[
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              key: ValueKey(
                  '${_featuredStop.gtfsStopId}|${_featuredStop.selectedDirectionKey}'),
              initialValue: _featuredStop.selectedDirectionKey,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Platform direction',
                prefixIcon: Icon(Icons.compare_arrows_rounded),
              ),
              items: _featuredStop.directionOptions
                  .map((option) => DropdownMenuItem(
                        value: option.key,
                        child: Text(option.label,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: (value) {
                if (value != null) _selectFeaturedDirection(value);
              },
            ),
          ],
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
            const SizedBox(height: 3),
            const Text(
                'ETA combines official schedules with live bus positions.',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _nearbyBusRoutes
                  .map((route) => ActionChip(
                        avatar:
                            const Icon(Icons.directions_bus_rounded, size: 16),
                        label: Text(_nearbyBusEtas[_routeKey(route)] == null
                            ? route
                            : '$route · ${_routeEtaLabel(_nearbyBusEtas[_routeKey(route)]!)}'),
                        tooltip: 'Show route $route on the live map',
                        onPressed: () => widget.onOpenBusRoute?.call(route),
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
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _openFullTimetable,
            icon: const Icon(Icons.schedule_rounded),
            label: const Text('View full service timetable'),
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

  String _routeKey(String value) => value
      .toUpperCase()
      .replaceAll('RAPID KL', '')
      .split('—')
      .first
      .replaceAll(RegExp(r'[^A-Z0-9]'), '');

  String _routeEtaLabel(BusArrivalEstimate estimate) =>
      '${estimate.etaLabel} ${estimate.stop.isLiveEstimate ? 'live' : 'scheduled'}';
}
