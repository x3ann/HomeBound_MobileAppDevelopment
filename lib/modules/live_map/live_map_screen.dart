import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/location_service.dart';
import '../../services/bus_arrival_service.dart';
import '../../services/gtfs_service.dart';
import '../../services/realtime_transit_service.dart';
import '../../services/transit_repository.dart';
import '../../services/walking_route_service.dart';
import '../../shared/models/stop.dart';
import '../../shared/models/bus_arrival_estimate.dart';
import '../../shared/models/planned_journey.dart';
import '../../shared/models/transit_shape.dart';
import '../../shared/models/transit_vehicle.dart';
import '../../shared/models/walking_route.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/data_source_badge.dart';
import 'widgets/stop_list_tile.dart';
import 'widgets/stop_pin.dart';

/// Shows the phone, nearby rail stops, and official GTFS-Realtime bus
/// vehicle positions. Location tracking starts automatically —
/// no button tap required — so the map is centered on the user and stops
/// are distance-sorted from the first frame.
class LiveMapScreen extends StatefulWidget {
  final String? initialQuery;
  final PlannedJourney? initialJourney;

  const LiveMapScreen({
    super.key,
    this.initialQuery,
    this.initialJourney,
  });

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen>
    with WidgetsBindingObserver {
  final _mapController = MapController();
  final _searchController = TextEditingController();
  StreamSubscription<LatLng>? _locationSubscription;
  Timer? _vehicleTimer;
  Timer? _countdownTimer;
  Timer? _scheduleTimer;
  bool _loading = true;
  bool _loadingVehicles = false;
  bool _mapReady = false;
  bool _loadingArrivals = false;
  bool _loadingBusStops = false;
  List<Stop> _stops = const [];
  List<Stop> _busStops = const [];
  List<TransitVehicle> _vehicles = const [];
  List<BusArrivalEstimate> _busArrivals = const [];
  List<TransitShape> _railShapes = const [];
  TransitDataSource _source = TransitDataSource.unavailable;
  LatLng? _userLocation;
  LatLng? _lastBusStopCenter;
  DateTime? _lastBusStopAttempt;
  Stop? _selectedStop;
  bool _selectedStopExpanded = false;
  String _query = '';
  String? _liveMessage;
  String? _locationMessage;
  LocationStatus? _locationStatus;
  DateTime? _lastVehicleUpdate;
  double _zoom = 14;
  double _nearbyRadiusKm = 2;
  String _modeFilter = 'All';
  String _lineFilter = 'All';
  WalkingRoute? _walkingRoute;
  bool _loadingWalkingRoute = false;
  String? _walkingRouteMessage;
  LatLng? _lastRoutedFrom;
  DateTime? _lastRouteAt;
  bool _initialFocusApplied = false;
  bool _handlingClockChange = false;
  bool _scheduleRefreshPending = false;
  DateTime _lastClockReading = DateTime.now();
  final _walkingRoutes = WalkingRouteService();
  PlannedJourney? _journey;
  bool _followJourneyLocation = false;
  double? _journeyLocationProgress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _journey = widget.initialJourney;
    _query = widget.initialQuery ?? '';
    _searchController.text = _query;
    if (_query.isNotEmpty) _modeFilter = 'Bus';
    _load();
    _searchController
        .addListener(() => setState(() => _query = _searchController.text));
    _startLocationTracking();
    _refreshVehicles();
    _vehicleTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _refreshVehicles());
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _stops.isEmpty) return;
      final now = DateTime.now();
      final elapsed = now.difference(_lastClockReading).inSeconds;
      _lastClockReading = now;
      if (elapsed < 0 || elapsed > 5) {
        unawaited(_handleClockChange());
        return;
      }
      var departureExpired = false;
      setState(() {
        _stops = _stops.map((stop) {
          if (!stop.isOperating ||
              !stop.hasDepartureData ||
              stop.timeToDeparture <= Duration.zero) {
            return stop;
          }
          final remaining = stop.timeToDeparture - const Duration(seconds: 1);
          if (remaining <= Duration.zero) departureExpired = true;
          return stop.copyWith(timeToDeparture: remaining);
        }).toList();
      });
      if (departureExpired && !_scheduleRefreshPending) {
        _scheduleRefreshPending = true;
        unawaited(_recalculateSchedule().whenComplete(
          () => _scheduleRefreshPending = false,
        ));
      }
    });
    _scheduleTimer = Timer.periodic(
        const Duration(minutes: 1), (_) => _recalculateSchedule());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _lastClockReading = DateTime.now();
      unawaited(_handleClockChange());
    }
  }

  Future<void> _handleClockChange() async {
    if (_handlingClockChange) return;
    _handlingClockChange = true;
    try {
      BusArrivalService.instance.clearCache();
      _lastBusStopAttempt = null;
      _lastBusStopCenter = null;
      await _recalculateSchedule();
      final location = _userLocation;
      if (location != null) await _refreshNearbyBusStops(location);
      await _refreshVehicles();
    } finally {
      _handlingClockChange = false;
    }
  }

  Future<void> _load() async {
    final result = await TransitRepository.instance.getNearbyStops();
    List<TransitShape> shapes = const [];
    try {
      shapes = await TransitRepository.instance.getRailShapes();
    } catch (_) {
      // Stops and the base map remain usable when optional shapes fail.
    }
    if (!mounted) return;
    final location = _userLocation;
    setState(() {
      _stops = location == null
          ? result.stops
          : TransitRepository.instance.sortByDistance(result.stops, location);
      _source = result.source;
      _railShapes = shapes;
      _loading = false;
    });
    if (_journey != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusJourney());
    }
    if (_journey?.route.mode.toLowerCase().contains('bus') == true) {
      unawaited(_loadJourneyBusShapes());
    }
  }

  Future<void> _loadJourneyBusShapes() async {
    final busShapeGroups = await Future.wait([
      'rapid-bus-kl',
      'rapid-bus-mrtfeeder',
    ].map((category) async {
      try {
        return await TransitRepository.instance
            .getTransitShapes(category: category);
      } catch (_) {
        return const <TransitShape>[];
      }
    }));
    if (!mounted || _journey == null) return;
    setState(() {
      _railShapes = [
        ..._railShapes,
        ...busShapeGroups.expand((group) => group)
      ];
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusJourney());
  }

  Future<void> _recalculateSchedule() async {
    final result = await TransitRepository.instance.recalculateStops();
    if (!mounted) return;
    final location = _userLocation;
    setState(() {
      final updatedStops = location == null
          ? result.stops
          : TransitRepository.instance.sortByDistance(result.stops, location);
      _stops = updatedStops;
      final selected = _selectedStop;
      if (selected != null && selected.transportMode != 'Bus') {
        for (final stop in updatedStops) {
          if (stop.gtfsStopId == selected.gtfsStopId) {
            _selectedStop = stop;
            break;
          }
        }
      }
      _source = result.source;
    });
  }

  Future<void> _refreshLocation() async {
    setState(() => _locationMessage = 'Refreshing your current location…');
    await _startLocationTracking();
    final location = _userLocation;
    if (mounted && location != null && _mapReady) {
      _mapController.move(location, 15);
    }
  }

  Future<void> _startLocationTracking() async {
    _locationSubscription?.cancel();
    final result = await LocationService.instance.requestCurrentLocation();
    if (!mounted) return;
    if (result.status != LocationStatus.available) {
      setState(() {
        _locationStatus = result.status;
        _locationMessage = switch (result.status) {
          LocationStatus.disabled =>
            'Turn on Location Services to see nearby transport.',
          LocationStatus.denied => 'Location permission was not granted.',
          LocationStatus.deniedForever =>
            'Location permission is blocked in phone settings.',
          _ => 'Your current location could not be found.',
        };
      });
      return;
    }
    _applyLocation(result.position!);
    _locationSubscription = LocationService.instance.watchPosition().listen(
      _applyLocation,
      onError: (_) {
        if (mounted) {
          setState(() => _locationMessage =
              'Live location updates paused. Tap retry to reconnect.');
        }
      },
    );
  }

  void _applyLocation(LatLng position) {
    if (!mounted) return;
    setState(() {
      _userLocation = position;
      _locationStatus = LocationStatus.available;
      _locationMessage = null;
      _stops = TransitRepository.instance.sortByDistance(_stops, position);
      _busStops =
          TransitRepository.instance.sortByDistance(_busStops, position);
      final locationProgress = _journey?.progressForPosition(position);
      if (locationProgress != null) {
        _journeyLocationProgress = math.max(
          _journeyLocationProgress ?? 0,
          locationProgress,
        );
      }
    });
    if (_mapReady) {
      if (_journey != null && _followJourneyLocation) {
        _mapController.move(position, 16.5);
      } else if (_selectedStop == null && _journey == null) {
        _mapController.move(position, 14.5);
      }
    }
    _refreshBusArrivals();
    _refreshNearbyBusStops(position);
    _maybeRefreshWalkingRoute(position);
  }

  Future<void> _refreshNearbyBusStops(LatLng position) async {
    if (_loadingBusStops) return;
    const distance = Distance();
    if (_lastBusStopCenter != null &&
        distance.as(LengthUnit.Meter, _lastBusStopCenter!, position) < 250) {
      return;
    }
    final now = DateTime.now();
    if (_lastBusStopAttempt != null &&
        now.difference(_lastBusStopAttempt!) < const Duration(seconds: 30)) {
      return;
    }
    _lastBusStopAttempt = now;
    _loadingBusStops = true;
    final stops = <Stop>[];
    try {
      for (final category in const [
        'rapid-bus-kl',
        'rapid-bus-mrtfeeder',
      ]) {
        try {
          stops.addAll(await BusArrivalService.instance.nearbyStops(
            userLocation: position,
            radiusMeters: 2000,
            category: category,
          ));
        } catch (_) {
          // Keep stops from the other official feed.
        }
      }
      final unique = <String, Stop>{};
      for (final stop in stops) {
        unique.putIfAbsent(
          '${stop.gtfsStopId}|${stop.position.latitude.toStringAsFixed(5)}',
          () => stop,
        );
      }
      if (!mounted) return;
      setState(() {
        _busStops = unique.values.toList();
        final selected = _selectedStop;
        if (selected != null && selected.transportMode == 'Bus') {
          for (final stop in _busStops) {
            if (stop.gtfsStopId == selected.gtfsStopId) {
              _selectedStop = stop;
              break;
            }
          }
        }
        if (unique.isNotEmpty) _lastBusStopCenter = position;
      });
    } finally {
      _loadingBusStops = false;
    }
  }

  Future<void> _resolveLocationIssue() async {
    if (_locationStatus == LocationStatus.deniedForever) {
      await LocationService.instance.openAppSettings();
    } else if (_locationStatus == LocationStatus.disabled) {
      await LocationService.instance.openLocationSettings();
    }
    await _startLocationTracking();
  }

  Future<void> _refreshVehicles() async {
    if (_loadingVehicles) return;
    setState(() => _loadingVehicles = true);
    try {
      final feeds = await Future.wait(const [
        'rapid-bus-kl',
        'rapid-bus-mrtfeeder',
      ].map((category) async {
        try {
          return (
            succeeded: true,
            vehicles: await RealtimeTransitService.instance
                .fetchVehicles(category: category),
          );
        } catch (_) {
          return (succeeded: false, vehicles: const <TransitVehicle>[]);
        }
      }));
      if (!feeds.any((feed) => feed.succeeded)) {
        throw StateError('All live vehicle feeds are unavailable.');
      }
      final vehicles = feeds.expand((feed) => feed.vehicles).toList();
      if (!mounted) return;
      setState(() {
        _vehicles = vehicles;
        if (vehicles.isEmpty) _busArrivals = const [];
        _lastVehicleUpdate = DateTime.now();
        _liveMessage = '${vehicles.length} live Rapid KL buses';
      });
      await _refreshBusArrivals();
    } catch (_) {
      if (!mounted) return;
      setState(
          () => _liveMessage = 'Live vehicle feed is temporarily unavailable.');
    } finally {
      if (mounted) setState(() => _loadingVehicles = false);
    }
  }

  Future<void> _refreshBusArrivals() async {
    final location = _userLocation;
    if (_loadingArrivals || location == null) return;
    if (_vehicles.isEmpty) {
      if (mounted && _busArrivals.isNotEmpty) {
        setState(() => _busArrivals = const []);
      }
      return;
    }
    _loadingArrivals = true;
    final estimates = <BusArrivalEstimate>[];
    try {
      for (final category in const [
        'rapid-bus-kl',
        'rapid-bus-mrtfeeder',
      ]) {
        final matching = _vehicles
            .where((vehicle) => vehicle.feedCategory == category)
            .toList();
        if (matching.isEmpty) continue;
        try {
          estimates.addAll(await BusArrivalService.instance.estimateArrivals(
            vehicles: matching,
            userLocation: location,
            category: category,
          ));
        } catch (_) {
          // Keep estimates from the other official bus feed.
        }
      }
      estimates.sort((a, b) => a.eta.compareTo(b.eta));
      if (mounted) {
        const distance = Distance();
        setState(() => _busArrivals = estimates
            .where((arrival) =>
                distance.as(
                    LengthUnit.Kilometer, location, arrival.stop.position) <=
                _nearbyRadiusKm)
            .take(8)
            .toList());
        _applyInitialFocus();
      }
    } finally {
      _loadingArrivals = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationSubscription?.cancel();
    _vehicleTimer?.cancel();
    _countdownTimer?.cancel();
    _scheduleTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.gold));
    }
    // The nearest stop is index 0 once sortByDistance has run (or the
    // app's default order before a location fix arrives).
    final center =
        _userLocation ?? (_stops.isEmpty ? null : _stops.first.position);
    final shownVehicles = _matchingVehicles();
    final shownStops = _matchingStops();
    const distance = Distance();
    final shownBusArrivals = _busArrivals
        .where((arrival) =>
            (_modeFilter == 'All' || _modeFilter == 'Bus') &&
            (_query.trim().isEmpty ||
                _routeSearchKey(arrival.routeLabel)
                    .contains(_routeSearchKey(_query)) ||
                arrival.stop.name
                    .toLowerCase()
                    .contains(_query.trim().toLowerCase())) &&
            (_userLocation == null ||
                distance.as(LengthUnit.Kilometer, _userLocation!,
                        arrival.stop.position) <=
                    _nearbyRadiusKm))
        .toList();
    final clusters = _clusterStops(shownStops);
    final journey = _journey;
    final journeyShapes = journey == null
        ? const <TransitShape>[]
        : _railShapes.where(_shapeMatchesJourney).toList();

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Row(children: [
          Expanded(
              child: Text(_liveMessage ?? 'Locating nearby transport…',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary),
                  overflow: TextOverflow.ellipsis)),
          DataSourceBadge(source: _source),
        ]),
      ),
      if (_locationMessage != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Row(children: [
            Expanded(
              child: Text(_locationMessage!,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            ),
            TextButton(
                onPressed: _resolveLocationIssue,
                child: Text(_locationStatus == LocationStatus.deniedForever
                    ? 'Settings'
                    : 'Retry')),
          ]),
        ),
      if (journey != null)
        _JourneyOverviewCard(
          journey: journey,
          serviceSeconds: GtfsService.secondsIntoServiceDay(DateTime.now()),
          locationProgress: _journeyLocationProgress,
          onFocus: _focusJourney,
          onExit: _exitJourney,
        ),
      if (journey == null) ...[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search a station, bus route, or vehicle',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _loadingVehicles
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(
                      onPressed: _refreshVehicles,
                      icon: const Icon(Icons.refresh_rounded)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 38,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            children: [
              for (final mode in const [
                'All',
                'Bus',
                'LRT',
                'MRT',
                'Monorail',
                'BRT',
              ]) ...[
                ChoiceChip(
                  label: Text(mode),
                  selected: _modeFilter == mode,
                  onSelected: (_) => setState(() {
                    _modeFilter = mode;
                    _lineFilter = 'All';
                    _selectedStop = null;
                    _walkingRoute = null;
                  }),
                ),
                const SizedBox(width: 6),
              ],
            ],
          ),
        ),
        ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: DropdownButtonFormField<String>(
              initialValue: _lineFilter,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: _modeFilter == 'Bus'
                    ? 'Bus route shown on map'
                    : 'Line shown on map',
                prefixIcon: const Icon(Icons.route_rounded),
              ),
              items: _availableLines
                  .map((line) => DropdownMenuItem(
                        value: line,
                        child: Text(
                          line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ))
                  .toList(),
              onChanged: (line) => setState(() {
                _lineFilter = line ?? 'All';
                _selectedStop = null;
                _walkingRoute = null;
              }),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              const Text('Nearby radius',
                  style:
                      TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              const SizedBox(width: 10),
              for (final radius in const [1.0, 2.0]) ...[
                ChoiceChip(
                  label: Text('${radius.toInt()} km'),
                  selected: _nearbyRadiusKm == radius,
                  onSelected: (_) => setState(() {
                    _nearbyRadiusKm = radius;
                    if (_selectedStop != null &&
                        (_selectedStop!.distanceMeters ?? double.infinity) >
                            radius * 1000) {
                      _selectedStop = null;
                    }
                  }),
                ),
                const SizedBox(width: 6),
              ],
              const Spacer(),
              Text('${shownStops.length} stops',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 11)),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
      Expanded(
        flex: journey != null ? 6 : 4,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Stack(
              children: [
                Positioned.fill(
                  child: center == null
                      ? const Center(child: Text('Map data is unavailable'))
                      : FlutterMap(
                          mapController: _mapController,
                          options: MapOptions(
                            initialCenter: center,
                            initialZoom: 14,
                            onPositionChanged: (position, _) {
                              final zoom = position.zoom;
                              if (zoom != null &&
                                  (zoom - _zoom).abs() >= 0.25) {
                                setState(() => _zoom = zoom);
                              }
                            },
                            onMapReady: () {
                              _mapReady = true;
                              if (_journey != null) {
                                _focusJourney();
                              } else if (_userLocation case final location?) {
                                _mapController.move(location, 14.5);
                              }
                            },
                          ),
                          children: [
                            TileLayer(
                                urlTemplate:
                                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                userAgentPackageName: 'com.homebound.app'),
                            PolylineLayer(
                              polylineCulling: true,
                              polylines: [
                                ...(journey == null
                                        ? _railShapes.where((shape) =>
                                            shape.points.length > 1 &&
                                            (_modeFilter == 'All' ||
                                                shape.transportMode ==
                                                    _modeFilter) &&
                                            (_lineFilter == 'All' ||
                                                shape.routeLabel ==
                                                    _lineFilter))
                                        : journeyShapes)
                                    .map((shape) => Polyline(
                                          points: shape.points,
                                          strokeWidth: journey == null ? 3 : 7,
                                          color: shape.color.withValues(
                                              alpha: journey == null
                                                  ? 0.75
                                                  : 0.95),
                                        )),
                                if (journey != null)
                                  Polyline(
                                    points: [
                                      journey.origin.position,
                                      journey.destination.position,
                                    ],
                                    strokeWidth: 4,
                                    color: AppColors.gold,
                                    isDotted: true,
                                  ),
                                if (_walkingRoute != null)
                                  Polyline(
                                    points: _walkingRoute!.points,
                                    strokeWidth: 6,
                                    color: Colors.blueAccent,
                                  )
                                else if (_selectedStop != null &&
                                    _userLocation != null)
                                  Polyline(
                                    points: [
                                      _userLocation!,
                                      _selectedStop!.position,
                                    ],
                                    strokeWidth: 5,
                                    color: Colors.blueAccent,
                                    isDotted: true,
                                  ),
                              ],
                            ),
                            MarkerLayer(markers: [
                              ...clusters.map((cluster) => Marker(
                                    point: cluster.center,
                                    width: 44,
                                    height: 44,
                                    child: cluster.stops.length == 1
                                        ? GestureDetector(
                                            onTap: () => _selectStop(
                                                cluster.stops.single),
                                            child: StopPin(
                                                stop: cluster.stops.single),
                                          )
                                        : _ClusterPin(
                                            count: cluster.stops.length,
                                            onTap: () => _mapController.move(
                                                cluster.center,
                                                math.min(_zoom + 2, 18)),
                                          ),
                                  )),
                              ...shownBusArrivals.map((arrival) => Marker(
                                    point: arrival.stop.position,
                                    width: 34,
                                    height: 34,
                                    child: GestureDetector(
                                      onTap: () => _selectStop(arrival.stop),
                                      child: Tooltip(
                                        message:
                                            '${arrival.routeLabel} · ${arrival.etaLabel}',
                                        child: const Icon(
                                            Icons.directions_bus_rounded,
                                            color: Colors.orangeAccent,
                                            size: 26),
                                      ),
                                    ),
                                  )),
                              if (_userLocation != null)
                                Marker(
                                    point: _userLocation!,
                                    width: 42,
                                    height: 42,
                                    child: const _UserLocationPin()),
                              if (journey != null) ...[
                                ...journey.route.checkpoints
                                    .asMap()
                                    .entries
                                    .map((entry) => Marker(
                                          point: entry.value.position,
                                          width: 40,
                                          height: 40,
                                          child: _JourneyCheckpointPin(
                                            number: entry.key + 1,
                                            label: entry.value.name,
                                          ),
                                        )),
                                Marker(
                                  point: journey.origin.position,
                                  width: 46,
                                  height: 46,
                                  child: const _JourneyEndpointPin(
                                    label: 'A',
                                    color: AppColors.success,
                                  ),
                                ),
                                Marker(
                                  point: journey.destination.position,
                                  width: 46,
                                  height: 46,
                                  child: const _JourneyEndpointPin(
                                    label: 'B',
                                    color: AppColors.critical,
                                  ),
                                ),
                              ],
                              ...shownVehicles.map((vehicle) => Marker(
                                  point: vehicle.position,
                                  width: 42,
                                  height: 42,
                                  child: _VehiclePin(vehicle: vehicle))),
                            ]),
                            RichAttributionWidget(
                              showFlutterMapAttribution: false,
                              attributions: [
                                TextSourceAttribution(
                                  'OpenStreetMap contributors',
                                  onTap: () => launchUrl(Uri.parse(
                                      'https://www.openstreetmap.org/copyright')),
                                ),
                                TextSourceAttribution(
                                  'Routing by OSRM',
                                  onTap: () => launchUrl(
                                      Uri.parse('https://project-osrm.org/')),
                                ),
                              ],
                            ),
                          ],
                        ),
                ),
                if (center != null)
                  Positioned(
                    right: 10,
                    top: 10,
                    child: Column(
                      children: [
                        _MapButton(
                            icon: Icons.add_rounded,
                            tooltip: 'Zoom in',
                            onPressed: () => _zoomBy(1)),
                        const SizedBox(height: 6),
                        _MapButton(
                            icon: Icons.remove_rounded,
                            tooltip: 'Zoom out',
                            onPressed: () => _zoomBy(-1)),
                        const SizedBox(height: 6),
                        if (_userLocation != null)
                          _MapButton(
                              icon: Icons.my_location_rounded,
                              tooltip: journey == null
                                  ? 'Refresh my location'
                                  : 'Follow my live location',
                              onPressed: () {
                                setState(() => _selectedStop = null);
                                if (journey != null) {
                                  _followJourneyLocation = true;
                                }
                                _refreshLocation();
                              }),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      if (journey == null) ...[
        if (_selectedStop case final selected?) ...[
          _SelectedStopCard(
            stop: selected,
            expanded: _selectedStopExpanded,
            walkingRoute: _walkingRoute,
            loadingRoute: _loadingWalkingRoute,
            routeMessage: _walkingRouteMessage,
            onClose: () => setState(() {
              _selectedStop = null;
              _selectedStopExpanded = false;
              _walkingRoute = null;
              _walkingRouteMessage = null;
            }),
            onToggleExpanded: () => setState(
              () => _selectedStopExpanded = !_selectedStopExpanded,
            ),
            onDirections:
                _userLocation == null ? null : () => _openDirections(selected),
          ),
          const SizedBox(height: 10),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            const Expanded(
                child: Text('Nearby stops',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            Text(
                '${shownStops.length} stops · ${shownVehicles.length} vehicles${_lastVehicleUpdate == null ? '' : ' · ${_timeLabel(_lastVehicleUpdate!)}'}',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary)),
          ]),
        ),
        const SizedBox(height: 8),
        if (shownBusArrivals.isNotEmpty)
          SizedBox(
            height: 88,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Text('Estimated bus arrivals from live positions',
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textSecondary)),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    scrollDirection: Axis.horizontal,
                    itemCount: shownBusArrivals.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, index) {
                      final arrival = shownBusArrivals[index];
                      return ActionChip(
                        avatar:
                            const Icon(Icons.directions_bus_rounded, size: 17),
                        label: Text(
                            '${arrival.routeLabel} · ${arrival.stop.name} · ${arrival.etaLabel}'),
                        onPressed: () => _selectStop(arrival.stop),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        Expanded(
            flex: 3,
            child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                children: shownStops
                    .map((stop) => StopListTile(
                          stop: stop,
                          onTap: () => _selectStop(stop),
                        ))
                    .toList())),
      ],
    ]);
  }

  bool _shapeMatchesJourney(TransitShape shape) {
    final journey = _journey;
    if (journey == null || shape.points.length < 2) return false;
    final routeText = '${journey.route.mode} ${journey.route.steps.join(' ')}'
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    final label = shape.routeLabel
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    if (label.isEmpty) return false;
    if (routeText.contains(label)) return true;
    final coreLabel = label.replaceAll(RegExp(r'\bline\b'), '').trim();
    return coreLabel.length >= 5 && routeText.contains(coreLabel);
  }

  void _focusJourney() {
    final journey = _journey;
    if (!_mapReady || journey == null) return;
    _followJourneyLocation = false;
    _mapController.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints([
        journey.origin.position,
        ...journey.route.checkpoints.map((checkpoint) => checkpoint.position),
        journey.destination.position,
      ]),
      padding: const EdgeInsets.fromLTRB(46, 70, 46, 70),
      maxZoom: 16,
    ));
  }

  void _exitJourney() {
    setState(() {
      _journey = null;
      _followJourneyLocation = false;
      _journeyLocationProgress = null;
    });
    final location = _userLocation;
    if (_mapReady && location != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mapController.move(location, 14.5);
      });
    }
  }

  List<TransitVehicle> _matchingVehicles() {
    final query = _query.trim().toLowerCase();
    const distance = Distance();
    return _vehicles.where((vehicle) {
      final matchesQuery = query.isEmpty ||
          vehicle.routeLabel.toLowerCase().contains(query) ||
          vehicle.id.toLowerCase().contains(query);
      final isNearby = _userLocation == null ||
          distance.as(LengthUnit.Kilometer, _userLocation!, vehicle.position) <=
              _nearbyRadiusKm;
      final isFresh =
          DateTime.now().difference(vehicle.updatedAt).inMinutes <= 5;
      final matchesMode = _modeFilter == 'All' || _modeFilter == 'Bus';
      return matchesQuery && isNearby && isFresh && matchesMode;
    }).toList();
  }

  List<Stop> _matchingStops() {
    final query = _query.trim().toLowerCase();
    final unique = <String, Stop>{};
    for (final stop in [..._stops, ..._busStops]) {
      unique.putIfAbsent(
        '${stop.transportMode}|${stop.gtfsStopId ?? stop.name}|${stop.position.latitude.toStringAsFixed(5)}',
        () => stop,
      );
    }
    final matches = unique.values
        .where((stop) {
          final matchesQuery = query.isEmpty ||
              stop.name.toLowerCase().contains(query) ||
              stop.platform.toLowerCase().contains(query) ||
              stop.routeLabel.toLowerCase().contains(query) ||
              stop.transportMode.toLowerCase().contains(query);
          final isNearby = _userLocation == null ||
              (stop.distanceMeters ?? double.infinity) <=
                  _nearbyRadiusKm * 1000;
          final matchesMode = _modeFilter == 'All' ||
              stop.transportMode
                  .toLowerCase()
                  .contains(_modeFilter.toLowerCase());
          final matchesLine =
              _lineFilter == 'All' || stop.routeLabel.contains(_lineFilter);
          return matchesQuery && isNearby && matchesMode && matchesLine;
        })
        .take(25)
        .toList();
    return matches;
  }

  void _selectStop(Stop stop) {
    setState(() {
      _selectedStop = stop;
      _selectedStopExpanded = false;
      _walkingRoute = null;
      _walkingRouteMessage = null;
    });
    final user = _userLocation;
    if (user != null) _loadWalkingRoute(stop);
    if (!_mapReady) return;
    if (user == null) {
      _mapController.move(stop.position, 16);
      return;
    }
    _mapController.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints([user, stop.position]),
      padding: const EdgeInsets.all(48),
      maxZoom: 16,
    ));
  }

  Future<void> _loadWalkingRoute(Stop stop) async {
    final user = _userLocation;
    if (user == null || _loadingWalkingRoute) return;
    setState(() {
      _loadingWalkingRoute = true;
      _walkingRouteMessage = null;
    });
    try {
      final route = await _walkingRoutes.route(user, stop.position);
      if (!mounted || _selectedStop != stop) return;
      setState(() {
        _walkingRoute = route;
        _lastRoutedFrom = user;
        _lastRouteAt = DateTime.now();
      });
      if (_mapReady) {
        _mapController.fitCamera(CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(route.points),
          padding: const EdgeInsets.all(42),
          maxZoom: 17,
        ));
      }
    } catch (_) {
      if (mounted && _selectedStop == stop) {
        setState(() => _walkingRouteMessage =
            'Road guidance is unavailable; showing a direct guide line.');
      }
    } finally {
      if (mounted) setState(() => _loadingWalkingRoute = false);
    }
  }

  void _maybeRefreshWalkingRoute(LatLng position) {
    final selected = _selectedStop;
    final previous = _lastRoutedFrom;
    if (selected == null || previous == null || _loadingWalkingRoute) return;
    const distance = Distance();
    final moved = distance.as(LengthUnit.Meter, previous, position);
    final oldEnough = _lastRouteAt == null ||
        DateTime.now().difference(_lastRouteAt!) > const Duration(seconds: 20);
    if (moved >= 30 && oldEnough) {
      _loadWalkingRoute(selected);
    }
  }

  void _applyInitialFocus() {
    if (_initialFocusApplied || widget.initialQuery == null) return;
    final needle = _routeSearchKey(widget.initialQuery!);
    final matches = _busArrivals
        .where((arrival) =>
            _routeSearchKey(arrival.routeLabel).contains(needle) ||
            needle.contains(_routeSearchKey(arrival.routeLabel)))
        .toList();
    if (matches.isEmpty) {
      final vehicles = _vehicles
          .where((vehicle) =>
              _routeSearchKey(vehicle.routeLabel).contains(needle) ||
              needle.contains(_routeSearchKey(vehicle.routeLabel)))
          .toList();
      if (vehicles.isEmpty || !_mapReady) return;
      _initialFocusApplied = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mapController.move(vehicles.first.position, 16);
      });
      return;
    }
    _initialFocusApplied = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _selectStop(matches.first.stop);
      }
    });
  }

  List<String> get _availableLines {
    final lines = <String>{};
    if (_modeFilter == 'All' || _modeFilter == 'Bus') {
      for (final stop in _busStops) {
        lines.addAll(stop.routeLabel
            .split(' · ')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty));
      }
    }
    if (_modeFilter != 'Bus') {
      lines.addAll(_railShapes
          .where((shape) =>
              _modeFilter == 'All' || shape.transportMode == _modeFilter)
          .map((shape) => shape.routeLabel));
    }
    final sorted = lines.toList()..sort();
    return ['All', ...sorted];
  }

  String _routeSearchKey(String value) => value
      .toUpperCase()
      .replaceAll('RAPID KL', '')
      .split('—')
      .first
      .replaceAll(RegExp(r'[^A-Z0-9]'), '');

  void _zoomBy(double change) {
    if (!_mapReady) return;
    final next = (_zoom + change).clamp(4.0, 18.0);
    _mapController.move(_mapController.camera.center, next);
  }

  Future<void> _openDirections(Stop stop) async {
    final user = _userLocation;
    if (user == null) return;
    final uri = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'origin': '${user.latitude},${user.longitude}',
      'destination': '${stop.position.latitude},${stop.position.longitude}',
      'travelmode': 'walking',
    });
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
          mounted) {
        setState(() => _liveMessage = 'Unable to open walking directions.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _liveMessage = 'Unable to open walking directions.');
      }
    }
  }

  String _timeLabel(DateTime time) {
    final local = time.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${local.hour >= 12 ? 'PM' : 'AM'}';
  }

  List<_StopCluster> _clusterStops(List<Stop> stops) {
    if (_zoom >= 15.5 || _query.trim().isNotEmpty) {
      return stops.map((stop) => _StopCluster(stop.position, [stop])).toList();
    }
    final cellSize = 0.02 / math.pow(2, math.max(0, _zoom - 12));
    final buckets = <String, List<Stop>>{};
    for (final stop in stops) {
      final latCell = (stop.position.latitude / cellSize).floor();
      final lonCell = (stop.position.longitude / cellSize).floor();
      buckets.putIfAbsent('$latCell:$lonCell', () => []).add(stop);
    }
    return buckets.values.map((group) {
      final lat =
          group.map((stop) => stop.position.latitude).reduce((a, b) => a + b) /
              group.length;
      final lon =
          group.map((stop) => stop.position.longitude).reduce((a, b) => a + b) /
              group.length;
      return _StopCluster(LatLng(lat, lon), group);
    }).toList();
  }
}

class _JourneyOverviewCard extends StatelessWidget {
  final PlannedJourney journey;
  final int serviceSeconds;
  final double? locationProgress;
  final VoidCallback onFocus;
  final VoidCallback onExit;

  const _JourneyOverviewCard({
    required this.journey,
    required this.serviceSeconds,
    required this.locationProgress,
    required this.onFocus,
    required this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    final progress = locationProgress ?? journey.progressAt(serviceSeconds);
    if (locationProgress != null && progress >= .995) {
      return _JourneyArrivalCard(
        journey: journey,
        onEndJourney: onExit,
      );
    }
    final steps = journey.route.steps;
    final activeIndex = locationProgress == null
        ? journey.activeStepAt(serviceSeconds)
        : journey.activeStepAtProgress(progress);
    final checkpoints = journey.route.checkpoints;
    final checkpointIndex = locationProgress == null
        ? journey.activeCheckpointAt(serviceSeconds)
        : journey.activeCheckpointAtProgress(progress);
    final instruction = steps.isEmpty
        ? 'Follow the selected ${journey.route.mode} journey.'
        : steps[activeIndex];
    final status = locationProgress != null
        ? progress >= .995
            ? 'Destination reached'
            : 'Live location progress · step ${activeIndex + 1} of ${steps.length}'
        : progress <= 0
            ? 'Upcoming · departs ${journey.route.departureTime}'
            : progress >= 1
                ? 'Scheduled journey complete'
                : 'Scheduled progress · step ${activeIndex + 1} of ${steps.length}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.gold.withValues(alpha: .55)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.navigation_rounded,
                    color: AppColors.gold, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${journey.origin.name} → ${journey.destination.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Focus whole journey',
                  onPressed: onFocus,
                  icon: const Icon(Icons.center_focus_strong_rounded,
                      color: AppColors.gold),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Exit journey view',
                  onPressed: onExit,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Text(
              '${journey.route.mode} · ${journey.route.durationLabel} · '
              '${journey.route.arrivalTime}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(8),
              backgroundColor: AppColors.surfaceAlt,
              color: AppColors.gold,
            ),
            const SizedBox(height: 7),
            Text(status,
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary)),
            const SizedBox(height: 5),
            Text(instruction,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            if (checkpoints.isNotEmpty) ...[
              const SizedBox(height: 7),
              Text(
                'Checkpoint ${checkpointIndex + 1}/${checkpoints.length}: '
                '${checkpoints[checkpointIndex].name} · '
                '${checkpoints[checkpointIndex].instruction}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _JourneyArrivalCard extends StatelessWidget {
  final PlannedJourney journey;
  final VoidCallback onEndJourney;

  const _JourneyArrivalCard({
    required this.journey,
    required this.onEndJourney,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        label: 'Destination reached. Arrived at ${journey.destination.name}.',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: AppColors.success.withValues(alpha: .75),
                width: 1.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: .16),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.check_rounded,
                        color: AppColors.success,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'YOU HAVE ARRIVED',
                            style: TextStyle(
                              color: AppColors.success,
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              letterSpacing: .8,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            journey.destination.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Journey complete · ${journey.route.durationLabel} planned · '
                  '${journey.route.mode}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onEndJourney,
                    icon: const Icon(Icons.done_all_rounded),
                    label: const Text('End journey'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _SelectedStopCard extends StatelessWidget {
  final Stop stop;
  final bool expanded;
  final VoidCallback onClose;
  final VoidCallback onToggleExpanded;
  final VoidCallback? onDirections;
  final WalkingRoute? walkingRoute;
  final bool loadingRoute;
  final String? routeMessage;

  const _SelectedStopCard({
    required this.stop,
    required this.expanded,
    required this.onClose,
    required this.onToggleExpanded,
    required this.onDirections,
    required this.walkingRoute,
    required this.loadingRoute,
    required this.routeMessage,
  });

  @override
  Widget build(BuildContext context) {
    final meters = stop.distanceMeters;
    final walkMinutes =
        meters == null ? null : math.max(1, (meters / 78).ceil());
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.gold.withValues(alpha: .4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  stop.transportMode == 'Bus'
                      ? Icons.directions_bus_rounded
                      : Icons.directions_transit_rounded,
                  color: AppColors.gold,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(stop.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w900)),
                ),
                if (onDirections != null)
                  IconButton(
                    onPressed: onDirections,
                    tooltip: 'Open walking directions',
                    icon: const Icon(Icons.directions_walk_rounded,
                        color: AppColors.gold),
                  ),
                IconButton(
                  onPressed: onToggleExpanded,
                  tooltip: expanded ? 'Show fewer details' : 'Show all details',
                  icon: Icon(expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded),
                ),
                IconButton(
                  onPressed: onClose,
                  tooltip: 'Close station details',
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            if (!expanded)
              Text(
                '${stop.transportMode} · ${stop.serviceStatusLabel} · '
                '${stop.isOperating ? 'Next ${stop.formattedCountdown}' : 'Currently closed'}'
                '${meters == null ? '' : ' · ${meters < 1000 ? '${meters.round()} m' : '${(meters / 1000).toStringAsFixed(1)} km'} away'}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11),
              ),
            if (expanded) ...[
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  _StopDetailPill(
                      icon: Icons.category_outlined, label: stop.transportMode),
                  _StopDetailPill(
                    icon: stop.isOperating
                        ? Icons.check_circle_outline_rounded
                        : Icons.nightlight_outlined,
                    label: stop.serviceStatusLabel,
                    color: stop.isOperating
                        ? AppColors.success
                        : AppColors.critical,
                  ),
                  _StopDetailPill(
                    icon: Icons.schedule_rounded,
                    label: stop.isOperating
                        ? 'Next ${stop.formattedCountdown}'
                        : 'Currently closed',
                  ),
                  if (stop.lastService != '—')
                    _StopDetailPill(
                      icon: Icons.last_page_rounded,
                      label: 'Last ${stop.lastService}',
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                stop.routeLabel.isEmpty
                    ? stop.platform
                    : 'Lines/routes: ${stop.routeLabel}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11, height: 1.3),
              ),
              if (walkMinutes != null)
                Text(
                  'From you: ${meters! < 1000 ? '${meters.round()} m' : '${(meters / 1000).toStringAsFixed(1)} km'} · about $walkMinutes min walk',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 11),
                ),
              if (loadingRoute)
                const Text('Finding a walking route along roads…',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 11)),
              if (walkingRoute case final route?) ...[
                Text(
                  'Road route: ${(route.distanceMeters / 1000).toStringAsFixed(1)} km · ${math.max(1, route.duration.inMinutes)} min',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 11),
                ),
                if (route.instructions.isNotEmpty)
                  Text(
                    'Next direction: ${route.instructions.first}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 11),
                  ),
              ],
              if (routeMessage != null)
                Text(routeMessage!,
                    style: const TextStyle(
                        color: AppColors.warning, fontSize: 11)),
              const SizedBox(height: 5),
              Text(
                'Stop ID: ${stop.gtfsStopId ?? 'Unavailable'} · '
                '${stop.position.latitude.toStringAsFixed(5)}, ${stop.position.longitude.toStringAsFixed(5)}',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 10),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StopDetailPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StopDetailPill({
    required this.icon,
    required this.label,
    this.color = AppColors.gold,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 10, color: color, fontWeight: FontWeight.w700)),
          ],
        ),
      );
}

class _MapButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _MapButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.surface,
        shape: const CircleBorder(),
        elevation: 3,
        child: IconButton(
          onPressed: onPressed,
          tooltip: tooltip,
          icon: Icon(icon, color: AppColors.gold),
        ),
      );
}

class _StopCluster {
  final LatLng center;
  final List<Stop> stops;
  const _StopCluster(this.center, this.stops);
}

class _ClusterPin extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _ClusterPin({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.gold,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: Text('$count',
              style: const TextStyle(
                  color: Colors.black, fontWeight: FontWeight.w800)),
        ),
      );
}

class _UserLocationPin extends StatelessWidget {
  const _UserLocationPin();
  @override
  Widget build(BuildContext context) => const Tooltip(
      message: 'Your current location',
      child:
          Icon(Icons.my_location_rounded, color: Colors.blueAccent, size: 34));
}

class _VehiclePin extends StatelessWidget {
  final TransitVehicle vehicle;
  const _VehiclePin({required this.vehicle});
  @override
  Widget build(BuildContext context) => Tooltip(
      message: '${vehicle.routeLabel}\nVehicle ${vehicle.id}',
      child: const Icon(Icons.directions_transit_rounded,
          color: AppColors.gold, size: 32));
}

class _JourneyEndpointPin extends StatelessWidget {
  final String label;
  final Color color;

  const _JourneyEndpointPin({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [
            BoxShadow(
                color: Colors.black38, blurRadius: 6, offset: Offset(0, 2)),
          ],
        ),
        child: Text(label,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w900)),
      );
}

class _JourneyCheckpointPin extends StatelessWidget {
  final int number;
  final String label;

  const _JourneyCheckpointPin({required this.number, required this.label});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Checkpoint $number · $label',
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.surface,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.gold, width: 3),
            boxShadow: const [
              BoxShadow(
                  color: Colors.black38, blurRadius: 5, offset: Offset(0, 2)),
            ],
          ),
          child: Text('$number',
              style: const TextStyle(
                  color: AppColors.gold, fontWeight: FontWeight.w900)),
        ),
      );
}
