import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../services/location_service.dart';
import '../../services/bus_arrival_service.dart';
import '../../services/realtime_transit_service.dart';
import '../../services/transit_repository.dart';
import '../../shared/models/stop.dart';
import '../../shared/models/bus_arrival_estimate.dart';
import '../../shared/models/transit_shape.dart';
import '../../shared/models/transit_vehicle.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/data_source_badge.dart';
import 'widgets/stop_list_tile.dart';
import 'widgets/stop_pin.dart';

/// Shows the phone, nearby rail stops, and official GTFS-Realtime bus
/// vehicle positions. Location tracking starts automatically —
/// no button tap required — so the map is centered on the user and stops
/// are distance-sorted from the first frame.
class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key});

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
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
  List<Stop> _stops = const [];
  List<TransitVehicle> _vehicles = const [];
  List<BusArrivalEstimate> _busArrivals = const [];
  List<TransitShape> _railShapes = const [];
  TransitDataSource _source = TransitDataSource.unavailable;
  LatLng? _userLocation;
  String _query = '';
  String? _liveMessage;
  String? _locationMessage;
  LocationStatus? _locationStatus;
  DateTime? _lastVehicleUpdate;
  double _zoom = 14;

  @override
  void initState() {
    super.initState();
    _load();
    _searchController
        .addListener(() => setState(() => _query = _searchController.text));
    _startLocationTracking();
    _refreshVehicles();
    _vehicleTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _refreshVehicles());
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _stops.isEmpty) return;
      setState(() {
        _stops = _stops
            .map((stop) => stop.timeToDeparture > Duration.zero
                ? stop.copyWith(
                    timeToDeparture:
                        stop.timeToDeparture - const Duration(seconds: 1))
                : stop)
            .toList();
      });
    });
    _scheduleTimer = Timer.periodic(
        const Duration(minutes: 1), (_) => _recalculateSchedule());
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
  }

  Future<void> _recalculateSchedule() async {
    final result = await TransitRepository.instance.recalculateStops();
    if (!mounted) return;
    final location = _userLocation;
    setState(() {
      _stops = location == null
          ? result.stops
          : TransitRepository.instance.sortByDistance(result.stops, location);
      _source = result.source;
    });
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
    });
    if (_mapReady) {
      _mapController.move(position, 14.5);
    }
    _refreshBusArrivals();
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
    if (_loadingArrivals || location == null || _vehicles.isEmpty) return;
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
      if (mounted) setState(() => _busArrivals = estimates.take(8).toList());
    } finally {
      _loadingArrivals = false;
    }
  }

  @override
  void dispose() {
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
    final clusters = _clusterStops(shownStops);

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
      Expanded(
        flex: 4,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: center == null
                ? const Center(child: Text('Map data is unavailable'))
                : FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: center,
                      initialZoom: 14,
                      onPositionChanged: (position, _) {
                        final zoom = position.zoom;
                        if (zoom != null && (zoom - _zoom).abs() >= 0.25) {
                          setState(() => _zoom = zoom);
                        }
                      },
                      onMapReady: () {
                        _mapReady = true;
                        final location = _userLocation;
                        if (location != null) {
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
                        polylines: _railShapes
                            .where((shape) => shape.points.length > 1)
                            .map((shape) => Polyline(
                                  points: shape.points,
                                  strokeWidth: 3,
                                  color: shape.color.withValues(alpha: 0.75),
                                ))
                            .toList(),
                      ),
                      MarkerLayer(markers: [
                        ...clusters.map((cluster) => Marker(
                              point: cluster.center,
                              width: 44,
                              height: 44,
                              child: cluster.stops.length == 1
                                  ? StopPin(stop: cluster.stops.single)
                                  : _ClusterPin(
                                      count: cluster.stops.length,
                                      onTap: () => _mapController.move(
                                          cluster.center,
                                          math.min(_zoom + 2, 18)),
                                    ),
                            )),
                        ..._busArrivals.map((arrival) => Marker(
                              point: arrival.stop.position,
                              width: 34,
                              height: 34,
                              child: Tooltip(
                                message:
                                    '${arrival.routeLabel} · ${arrival.etaLabel}',
                                child: const Icon(Icons.directions_bus_rounded,
                                    color: Colors.orangeAccent, size: 26),
                              ),
                            )),
                        if (_userLocation != null)
                          Marker(
                              point: _userLocation!,
                              width: 42,
                              height: 42,
                              child: const _UserLocationPin()),
                        ...shownVehicles.map((vehicle) => Marker(
                            point: vehicle.position,
                            width: 42,
                            height: 42,
                            child: _VehiclePin(vehicle: vehicle))),
                      ]),
                    ],
                  ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(children: [
          const Expanded(
              child: Text('Nearby stops',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
          Text(
              '${shownStops.length} stops · ${shownVehicles.length} vehicles${_lastVehicleUpdate == null ? '' : ' · ${_timeLabel(_lastVehicleUpdate!)}'}',
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary)),
        ]),
      ),
      const SizedBox(height: 8),
      if (_busArrivals.isNotEmpty)
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
                  itemCount: _busArrivals.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, index) {
                    final arrival = _busArrivals[index];
                    return ActionChip(
                      avatar:
                          const Icon(Icons.directions_bus_rounded, size: 17),
                      label: Text(
                          '${arrival.routeLabel} · ${arrival.stop.name} · ${arrival.etaLabel}'),
                      onPressed: () =>
                          _mapController.move(arrival.stop.position, 16),
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
                        onTap: () {
                          if (_mapReady) _mapController.move(stop.position, 16);
                        },
                      ))
                  .toList())),
    ]);
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
              8;
      final isFresh =
          DateTime.now().difference(vehicle.updatedAt).inMinutes <= 5;
      return matchesQuery && isNearby && isFresh;
    }).toList();
  }

  List<Stop> _matchingStops() {
    final query = _query.trim().toLowerCase();
    final matches = _stops
        .where((stop) {
          final matchesQuery = query.isEmpty ||
              stop.name.toLowerCase().contains(query) ||
              stop.platform.toLowerCase().contains(query);
          final isNearby = _userLocation == null ||
              (stop.distanceMeters ?? double.infinity) <= 8000;
          return matchesQuery && isNearby;
        })
        .take(25)
        .toList();
    if (matches.isEmpty && query.isEmpty) return _stops.take(25).toList();
    return matches;
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
