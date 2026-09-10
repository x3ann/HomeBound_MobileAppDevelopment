import 'package:flutter/material.dart';
import '../../shared/models/route_model.dart';
import '../../services/location_service.dart';
import '../../services/place_search_service.dart';
import '../../services/transit_repository.dart';
import '../../shared/models/stop.dart';
import '../../shared/theme/app_theme.dart';
import 'widgets/location_field.dart';
import 'widgets/route_card.dart';

/// Screen wires state (origin/destination controllers, search trigger)
/// into the widgets in modules/route_planner/widgets/. Origin is
/// auto-filled from the device's current location on open; the person
/// can still tap "Use current location" again to refresh it, or type an
/// origin manually.
class RoutePlannerScreen extends StatefulWidget {
  const RoutePlannerScreen({super.key});

  @override
  State<RoutePlannerScreen> createState() => _RoutePlannerScreenState();
}

class _RoutePlannerScreenState extends State<RoutePlannerScreen> {
  final _originController = TextEditingController();
  final _destinationController = TextEditingController();
  bool _searched = false;
  bool _locating = false;
  bool _planning = false;
  String? _validationMessage;
  List<Stop> _originSuggestions = const [];
  List<Stop> _destinationSuggestions = const [];
  int _originSearchVersion = 0;
  int _destinationSearchVersion = 0;
  List<RouteOption> _routes = const [];
  Stop? _selectedOrigin;
  Stop? _selectedDestination;
  Stop? _currentLocation;
  final _placeSearch = PlaceSearchService();

  @override
  void initState() {
    super.initState();
    _fillCurrentLocation();
  }

  @override
  void dispose() {
    _originController.dispose();
    _destinationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        const Text('Route Planner',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 16),
        LocationField(
            icon: Icons.trip_origin,
            hint: 'Current location or origin stop',
            controller: _originController,
            onChanged: (value) {
              _selectedOrigin = null;
              _findOriginSuggestions(value);
            }),
        if (_originSuggestions.isNotEmpty)
          _SuggestionList(
            stops: _originSuggestions,
            onSelected: (stop) => setState(() {
              _originController.text = stop.name;
              _selectedOrigin = stop;
              _originSuggestions = const [];
            }),
          ),
        Align(
          alignment: Alignment.center,
          child: IconButton.filledTonal(
            onPressed: _swapLocations,
            tooltip: 'Swap origin and destination',
            icon: const Icon(Icons.swap_vert_rounded),
          ),
        ),
        LocationField(
            icon: Icons.location_on_rounded,
            hint: 'Destination',
            controller: _destinationController,
            onChanged: (value) {
              _selectedDestination = null;
              _findDestinationSuggestions(value);
            }),
        if (_destinationSuggestions.isNotEmpty)
          _SuggestionList(
            stops: _destinationSuggestions,
            onSelected: (stop) => setState(() {
              _destinationController.text = stop.name;
              _selectedDestination = stop;
              _destinationSuggestions = const [];
            }),
          ),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: _locating ? null : _fillCurrentLocation,
          icon: _locating
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.my_location_rounded, size: 18),
          label: Text(_locating
              ? 'Finding your location…'
              : 'Use current location as origin'),
        ),
        if (_validationMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_validationMessage!,
                style: const TextStyle(fontSize: 12, color: Color(0xFFFFA6A6))),
          ),
        const SizedBox(height: 14),
        ElevatedButton(
          onPressed: _planning ? null : _findRoutes,
          child: _planning
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Find Routes'),
        ),
        const SizedBox(height: 22),
        if (_searched) ...[
          Text(
              '${_originController.text.trim()} → ${_destinationController.text.trim()}',
              style: const TextStyle(fontSize: 13, color: Color(0xFF9BA0C2))),
          const SizedBox(height: 12),
          if (_routes.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text(
                'Best route is ranked by total journey time and number of transfers.',
                style: TextStyle(fontSize: 11, color: Color(0xFF9BA0C2)),
              ),
            ),
          if (!_planning && _routes.isEmpty)
            const Text(
                'No scheduled rail journey was found for these stations today.',
                style: TextStyle(fontSize: 13, color: Color(0xFF9BA0C2)))
          else
            ..._routes.map((r) => RouteCard(route: r)),
        ],
      ],
    );
  }

  void _swapLocations() {
    final origin = _originController.text;
    _originController.text = _destinationController.text;
    _destinationController.text = origin;
    setState(() {
      final selectedOrigin = _selectedOrigin;
      _selectedOrigin = _selectedDestination;
      _selectedDestination = selectedOrigin;
      _originSuggestions = const [];
      _destinationSuggestions = const [];
      _routes = const [];
      _searched = false;
      _validationMessage = null;
    });
  }

  Future<void> _fillCurrentLocation() async {
    setState(() {
      _locating = true;
      _validationMessage = null;
    });
    final result = await LocationService.instance.requestCurrentLocation();
    if (!mounted) return;
    if (result.status == LocationStatus.available) {
      _currentLocation = Stop(
        name:
            'Current location (${result.position!.latitude.toStringAsFixed(4)}, ${result.position!.longitude.toStringAsFixed(4)})',
        platform: 'Your live location',
        position: result.position!,
        timeToDeparture: Duration.zero,
        urgency: ServiceUrgency.onTime,
        transportMode: 'Place',
        hasDepartureData: false,
      );
      _selectedOrigin = _currentLocation;
      _originController.text = _currentLocation!.name;
    } else {
      _validationMessage = result.status == LocationStatus.disabled
          ? 'Turn on Location Services, or type your origin manually.'
          : 'Location is unavailable. Type your origin manually.';
    }
    setState(() => _locating = false);
  }

  Future<void> _findRoutes() async {
    final origin = _originController.text.trim();
    final destination = _destinationController.text.trim();
    setState(() {
      _validationMessage = origin.isEmpty || destination.isEmpty
          ? 'Enter both an origin and a destination to plan your journey.'
          : null;
      _searched = origin.isNotEmpty && destination.isNotEmpty;
    });
    if (!_searched) return;
    setState(() {
      _planning = true;
      _routes = const [];
    });
    try {
      final originMatches = _selectedOrigin == null
          ? await TransitRepository.instance.searchStops(origin)
          : const <Stop>[];
      final destinationMatches = _selectedDestination == null
          ? await TransitRepository.instance.searchStops(destination)
          : const <Stop>[];
      final originStop = _selectedOrigin ??
          (originMatches.isEmpty ? null : originMatches.first);
      final destinationStop = _selectedDestination ??
          (destinationMatches.isEmpty ? null : destinationMatches.first);
      if (originStop == null || destinationStop == null) {
        if (mounted) {
          setState(() {
            _searched = false;
            _validationMessage =
                'Choose an origin and destination from the suggestions.';
          });
        }
        return;
      }
      final routes = await TransitRepository.instance
          .planRouteBetweenStops(originStop, destinationStop);
      if (mounted) setState(() => _routes = routes);
    } catch (_) {
      if (mounted) {
        setState(() => _validationMessage =
            'Route data is temporarily unavailable. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _planning = false);
    }
  }

  Future<void> _findOriginSuggestions(String query) async {
    final request = ++_originSearchVersion;
    if (query.trim().length < 2) {
      setState(() => _originSuggestions = const []);
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted || request != _originSearchVersion) return;
    final stops = await _searchSuggestions(query);
    if (!mounted || request != _originSearchVersion) return;
    setState(() => _originSuggestions = stops);
  }

  Future<void> _findDestinationSuggestions(String query) async {
    final request = ++_destinationSearchVersion;
    if (query.trim().length < 2) {
      setState(() => _destinationSuggestions = const []);
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted || request != _destinationSearchVersion) return;
    final stops = await _searchSuggestions(query);
    if (!mounted || request != _destinationSearchVersion) return;
    setState(() => _destinationSuggestions = stops);
  }

  Future<List<Stop>> _searchSuggestions(String query) async {
    final results = await Future.wait([
      TransitRepository.instance.searchStops(query),
      _placeSearch.search(query, near: _currentLocation?.position).catchError(
            (_) => <Stop>[],
          ),
    ]);
    final unique = <String, Stop>{};
    for (final stop in [...results[0], ...results[1]]) {
      unique.putIfAbsent(
        '${stop.name.toLowerCase()}|${stop.position.latitude.toStringAsFixed(4)}|${stop.position.longitude.toStringAsFixed(4)}',
        () => stop,
      );
    }
    return unique.values.take(8).toList();
  }
}

class _SuggestionList extends StatelessWidget {
  final List<Stop> stops;
  final ValueChanged<Stop> onSelected;

  const _SuggestionList({required this.stops, required this.onSelected});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF252946),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: stops
              .map((stop) => ListTile(
                    dense: true,
                    leading: Icon(
                      stop.transportMode == 'Place'
                          ? Icons.place_rounded
                          : Icons.train_rounded,
                      size: 18,
                    ),
                    title:
                        Text(stop.name, style: const TextStyle(fontSize: 14)),
                    subtitle: Text(
                        '${stop.transportMode} · ${stop.routeLabel.isEmpty ? stop.platform : stop.routeLabel}',
                        style: const TextStyle(fontSize: 11)),
                    onTap: () => onSelected(stop),
                  ))
              .toList(),
        ),
      );
}
