import 'package:flutter/material.dart';
import '../../shared/models/route_model.dart';
import '../../services/location_service.dart';
import '../../services/transit_repository.dart';
import '../../shared/models/stop.dart';
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
  String? _validationMessage;
  List<Stop> _suggestions = const [];
  int _searchVersion = 0;
  List<RouteOption> _routes = const [];

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
            controller: _originController),
        const SizedBox(height: 10),
        LocationField(
            icon: Icons.location_on_rounded,
            hint: 'Destination',
            controller: _destinationController,
            onChanged: _findSuggestions),
        if (_suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
                color: const Color(0xFF252946),
                borderRadius: BorderRadius.circular(12)),
            child: Column(
              children: _suggestions
                  .map((stop) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.train_rounded, size: 18),
                        title: Text(stop.name,
                            style: const TextStyle(fontSize: 14)),
                        subtitle: Text(stop.platform,
                            style: const TextStyle(fontSize: 11)),
                        onTap: () => setState(() {
                          _destinationController.text = stop.name;
                          _suggestions = const [];
                        }),
                      ))
                  .toList(),
            ),
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
          onPressed: _findRoutes,
          child: const Text('Find Routes'),
        ),
        const SizedBox(height: 22),
        if (_searched) ...[
          Text(
              '${_originController.text.trim()} → ${_destinationController.text.trim()}',
              style: const TextStyle(fontSize: 13, color: Color(0xFF9BA0C2))),
          const SizedBox(height: 12),
          if (_routes.isEmpty)
            const Text(
                'No direct scheduled rail journey was found. Try an interchange station.',
                style: TextStyle(fontSize: 13, color: Color(0xFF9BA0C2)))
          else
            ..._routes.map((r) => RouteCard(route: r)),
        ],
      ],
    );
  }

  Future<void> _fillCurrentLocation() async {
    setState(() {
      _locating = true;
      _validationMessage = null;
    });
    final result = await LocationService.instance.requestCurrentLocation();
    if (!mounted) return;
    if (result.status == LocationStatus.available) {
      _originController.text =
          'Current location (${result.position!.latitude.toStringAsFixed(4)}, ${result.position!.longitude.toStringAsFixed(4)})';
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
    final routes =
        await TransitRepository.instance.planRoute(origin, destination);
    if (mounted) setState(() => _routes = routes);
  }

  Future<void> _findSuggestions(String query) async {
    final request = ++_searchVersion;
    if (query.trim().length < 2) {
      setState(() => _suggestions = const []);
      return;
    }
    final stops = await TransitRepository.instance.searchStops(query);
    if (!mounted || request != _searchVersion) return;
    setState(() => _suggestions = stops);
  }
}
