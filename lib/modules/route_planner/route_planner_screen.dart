import 'package:flutter/material.dart';
import '../../shared/models/route_model.dart';
import '../../services/location_service.dart';
import '../../services/bus_arrival_service.dart';
import '../../services/place_search_service.dart';
import '../../services/saved_place_service.dart';
import '../../services/transit_repository.dart';
import '../../shared/models/stop.dart';
import '../../shared/models/saved_place.dart';
import '../../shared/theme/app_theme.dart';
import 'widgets/location_field.dart';
import 'widgets/route_card.dart';

/// Screen wires state (origin/destination controllers, search trigger)
/// into the widgets in modules/route_planner/widgets/. Origin is
/// auto-filled from the device's current location on open; the person
/// can still tap "Use current location" again to refresh it, or type an
/// origin manually.
class RoutePlannerScreen extends StatefulWidget {
  final Stop? initialOrigin;
  final Stop? initialDestination;

  const RoutePlannerScreen({
    super.key,
    this.initialOrigin,
    this.initialDestination,
  });

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
  final _savedPlaceService = SavedPlaceService();
  List<SavedPlace> _savedPlaces = const [];

  @override
  void initState() {
    super.initState();
    _loadSavedPlaces();
    final initialOrigin = widget.initialOrigin;
    final initialDestination = widget.initialDestination;
    if (initialOrigin != null && initialDestination != null) {
      _selectedOrigin = initialOrigin;
      _selectedDestination = initialDestination;
      _originController.text = initialOrigin.name;
      _destinationController.text = initialDestination.name;
      WidgetsBinding.instance.addPostFrameCallback((_) => _findRoutes());
    } else {
      _fillCurrentLocation();
    }
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
        const SizedBox(height: 6),
        Row(
          children: [
            const Text('Saved origins',
                style: TextStyle(fontSize: 12, color: Color(0xFF9BA0C2))),
            const Spacer(),
            TextButton.icon(
              onPressed: _selectedOrigin == null ? null : _saveCurrentOrigin,
              icon: const Icon(Icons.bookmark_add_outlined, size: 17),
              label: const Text('Save origin'),
            ),
          ],
        ),
        if (_savedPlaces.isEmpty)
          const Text('Save Home, Work, or another frequent starting point.',
              style: TextStyle(fontSize: 11, color: Color(0xFF9BA0C2)))
        else
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: _savedPlaces
                .map((place) => InputChip(
                      avatar: Icon(_savedPlaceIcon(place.slot), size: 17),
                      label: Text(place.slot),
                      tooltip: place.name,
                      onPressed: () => _useSavedPlace(place),
                      onDeleted: () => _removeSavedPlace(place),
                    ))
                .toList(),
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
                'No scheduled rail or direct bus journey was found for these locations today.',
                style: TextStyle(fontSize: 13, color: Color(0xFF9BA0C2)))
          else
            ..._routes.asMap().entries.map((entry) => RouteCard(
                  route: entry.value,
                  optionIndex: entry.key,
                  onTap: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (_) => RouteDetailsSheet(route: entry.value),
                  ),
                )),
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
      BusArrivalService.instance.searchScheduledStops(query),
      _placeSearch.search(query, near: _currentLocation?.position).catchError(
            (_) => <Stop>[],
          ),
    ]);
    final unique = <String, Stop>{};
    for (final stop in [...results[0], ...results[1], ...results[2]]) {
      unique.putIfAbsent(
        '${stop.name.toLowerCase()}|${stop.position.latitude.toStringAsFixed(4)}|${stop.position.longitude.toStringAsFixed(4)}',
        () => stop,
      );
    }
    return unique.values.take(8).toList();
  }

  Future<void> _loadSavedPlaces() async {
    try {
      final places = await _savedPlaceService.load();
      if (mounted) setState(() => _savedPlaces = places);
    } catch (_) {
      // Planning remains available when local preferences are unavailable.
    }
  }

  Future<void> _saveCurrentOrigin() async {
    final origin = _selectedOrigin;
    if (origin == null) return;
    final labelController = TextEditingController();
    final slot = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save origin as'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(origin.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              children: [
                for (final value in const ['Home', 'Work'])
                  ActionChip(
                    avatar: Icon(_savedPlaceIcon(value), size: 17),
                    label: Text(value),
                    onPressed: () => Navigator.pop(context, value),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: labelController,
              autofocus: true,
              maxLength: 24,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Custom label',
                hintText: 'Example: Campus or Mum’s house',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final label = labelController.text.trim();
              if (label.isNotEmpty) Navigator.pop(context, label);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    labelController.dispose();
    if (slot == null) return;
    await _savedPlaceService.save(SavedPlace(
      slot: slot,
      name: origin.name,
      position: origin.position,
    ));
    await _loadSavedPlaces();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$slot origin saved.')));
    }
  }

  void _useSavedPlace(SavedPlace place) {
    final stop = Stop(
      name: place.name,
      platform: 'Saved ${place.slot} location',
      position: place.position,
      timeToDeparture: Duration.zero,
      urgency: ServiceUrgency.onTime,
      transportMode: 'Place',
      hasDepartureData: false,
    );
    setState(() {
      _selectedOrigin = stop;
      _originController.text = place.name;
      _originSuggestions = const [];
      _routes = const [];
      _searched = false;
    });
  }

  Future<void> _removeSavedPlace(SavedPlace place) async {
    await _savedPlaceService.remove(place.slot);
    await _loadSavedPlaces();
  }

  IconData _savedPlaceIcon(String slot) => switch (slot) {
        'Home' => Icons.home_rounded,
        'Work' => Icons.work_rounded,
        _ => Icons.place_rounded,
      };
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
