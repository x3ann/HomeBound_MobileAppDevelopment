import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/delay_prediction_service.dart';
import '../../services/transit_repository.dart';
import '../../shared/models/delay_prediction.dart';
import '../../shared/models/stop.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/data_source_badge.dart';

class AiDelayPredictionScreen extends StatefulWidget {
  const AiDelayPredictionScreen({super.key});

  @override
  State<AiDelayPredictionScreen> createState() =>
      _AiDelayPredictionScreenState();
}

class _AiDelayPredictionScreenState extends State<AiDelayPredictionScreen> {
  final _repository = TransitRepository.instance;
  final _predictionService = DelayPredictionService();

  List<Stop> _stations = const [];
  Stop? _fromStation;
  Stop? _toStation;
  DelayPrediction? _prediction;
  TransitDataSource _source = TransitDataSource.unavailable;
  bool _loadingStations = true;
  bool _predicting = false;
  String? _loadError;
  String _modeFilter = 'All';
  String? _lineFilter;

  @override
  void initState() {
    super.initState();
    _loadStations();
  }

  Future<void> _loadStations() async {
    setState(() {
      _loadingStations = true;
      _loadError = null;
    });
    try {
      final stations = await _repository.getStationDirectory();
      if (stations.isEmpty) {
        throw const FormatException('The official station directory is empty.');
      }
      if (!mounted) return;
      setState(() {
        _stations = stations;
        _source = _repository.lastSource;
        _loadingStations = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Unable to load the official station directory.';
        _loadingStations = false;
      });
    }
  }

  Future<void> _predictDelay() async {
    final origin = _fromStation;
    final destination = _toStation;
    if (origin == null || destination == null) {
      _showMessage('Select an origin and destination.');
      return;
    }
    if (origin.gtfsStopId == destination.gtfsStopId) {
      _showMessage('Origin and destination cannot be the same.');
      return;
    }
    setState(() {
      _predicting = true;
      _prediction = null;
    });
    try {
      final prediction = await _predictionService.predict(
        origin: origin,
        destination: destination,
      );
      if (!mounted) return;
      setState(() {
        _prediction = prediction;
        _source = _repository.lastSource;
        _predicting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _predicting = false);
      _showMessage('Live inputs could not be loaded. Please try again.');
    }
  }

  void _swapStations() {
    setState(() {
      final previous = _fromStation;
      _fromStation = _toStation;
      _toStation = previous;
      _prediction = null;
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Color _riskColor(int score) => score >= 70
      ? AppColors.critical
      : score >= 35
          ? AppColors.warning
          : AppColors.success;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Delay Risk Estimate',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            onPressed: _loadingStations ? null : _loadStations,
            tooltip: 'Refresh official data',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: _loadingStations
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? _ErrorState(message: _loadError!, onRetry: _loadStations)
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 30),
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text('Check Your Journey',
                                style: TextStyle(
                                    fontSize: 20, fontWeight: FontWeight.w800)),
                          ),
                          DataSourceBadge(source: _source),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Uses official schedules and current weather. Results are estimates, not guaranteed arrival times.',
                        style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            height: 1.4),
                      ),
                      const SizedBox(height: 20),
                      _routeSelector(),
                      const SizedBox(height: 18),
                      ElevatedButton.icon(
                        onPressed: _predicting ? null : _predictDelay,
                        icon: _predicting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.auto_graph_rounded),
                        label: Text(_predicting
                            ? 'Checking live inputs…'
                            : 'Estimate Delay Risk'),
                      ),
                      if (_prediction == null && !_predicting)
                        const _EmptyState(),
                      if (_prediction case final prediction?) ...[
                        const SizedBox(height: 28),
                        _resultCard(prediction),
                        const SizedBox(height: 14),
                        _detailsCard(prediction),
                      ],
                    ],
                  ),
      ),
    );
  }

  Widget _routeSelector() {
    final filteredStations = _filteredStations;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _modeDropdown()),
              const SizedBox(width: 10),
              Expanded(child: _lineDropdown()),
            ],
          ),
          const SizedBox(height: 14),
          _stationDropdown(
            label: 'FROM',
            value: _fromStation,
            hint: 'Select origin station',
            stations: filteredStations,
            onChanged: (value) => setState(() {
              _fromStation = value;
              _prediction = null;
            }),
          ),
          IconButton(
            onPressed: _swapStations,
            tooltip: 'Swap stations',
            icon: const Icon(Icons.swap_vert_rounded, color: AppColors.gold),
          ),
          _stationDropdown(
            label: 'TO',
            value: _toStation,
            hint: 'Select destination station',
            stations: filteredStations,
            onChanged: (value) => setState(() {
              _toStation = value;
              _prediction = null;
            }),
          ),
        ],
      ),
    );
  }

  Widget _stationDropdown({
    required String label,
    required Stop? value,
    required String hint,
    required ValueChanged<Stop?> onChanged,
    required List<Stop> stations,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1)),
        const SizedBox(height: 7),
        DropdownButtonFormField<Stop>(
          initialValue: value,
          isExpanded: true,
          dropdownColor: AppColors.surface,
          hint: Text(hint),
          items: stations
              .map((station) => DropdownMenuItem(
                    value: station,
                    child: Text(station.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _resultCard(DelayPrediction result) {
    final color = _riskColor(result.riskScore);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Column(
        children: [
          Text('${result.riskScore}%',
              style: TextStyle(
                  color: color, fontSize: 46, fontWeight: FontWeight.w900)),
          Text(result.riskLevel,
              style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2)),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                  child: _metric('Estimated delay',
                      '+${result.expectedDelayMinutes} min')),
              const SizedBox(width: 10),
              Expanded(child: _metric('Confidence', result.confidence)),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: _metric(
              'Total estimated journey time',
              result.totalEstimatedMinutes <= 0
                  ? 'Unavailable'
                  : '${result.totalEstimatedMinutes} min',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _metric('Weather', result.weatherSummary)),
              const SizedBox(width: 10),
              Expanded(
                  child: _metric('Estimated arrival', result.estimatedArrival)),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: _metric('Route availability', result.serviceSummary),
          ),
        ],
      ),
    );
  }

  List<Stop> get _filteredStations => _stations.where((station) {
        final modeMatches = _modeFilter == 'All' ||
            station.transportMode
                .toLowerCase()
                .contains(_modeFilter.toLowerCase());
        final lineMatches = _lineFilter == null ||
            station.routeLabel
                .toLowerCase()
                .contains(_lineFilter!.toLowerCase());
        return modeMatches && lineMatches;
      }).toList();

  List<String> get _modeOptions {
    final values = <String>{};
    for (final station in _stations) {
      values.addAll(station.transportMode
          .split('/')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty && value != 'Rail'));
    }
    final sorted = values.toList()..sort();
    return ['All', ...sorted];
  }

  List<String> get _lineOptions {
    final values = <String>{};
    for (final station in _stations) {
      if (_modeFilter != 'All' &&
          !station.transportMode
              .toLowerCase()
              .contains(_modeFilter.toLowerCase())) {
        continue;
      }
      values.addAll(station.routeLabel
          .split(' · ')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty));
    }
    return values.toList()..sort();
  }

  Widget _modeDropdown() => DropdownButtonFormField<String>(
        initialValue: _modeFilter,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Transport type'),
        items: _modeOptions
            .map((mode) => DropdownMenuItem(value: mode, child: Text(mode)))
            .toList(),
        onChanged: (value) => setState(() {
          _modeFilter = value ?? 'All';
          _lineFilter = null;
          _fromStation = null;
          _toStation = null;
          _prediction = null;
        }),
      );

  Widget _lineDropdown() => DropdownButtonFormField<String>(
        initialValue: _lineFilter,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Line'),
        hint: const Text('All lines'),
        items: [
          const DropdownMenuItem<String>(value: null, child: Text('All lines')),
          ..._lineOptions.map(
            (line) => DropdownMenuItem(
                value: line,
                child: Text(
                  line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )),
          ),
        ],
        onChanged: (value) => setState(() {
          _lineFilter = value;
          _fromStation = null;
          _toStation = null;
          _prediction = null;
        }),
      );

  Widget _metric(String title, String value) => Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(13),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11)),
            const SizedBox(height: 5),
            Text(value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
      );

  Widget _detailsCard(DelayPrediction result) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Why this estimate?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            for (final factor in result.factors)
              Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle_outline_rounded,
                        size: 18, color: AppColors.gold),
                    const SizedBox(width: 9),
                    Expanded(
                        child: Text(factor,
                            style: const TextStyle(
                                color: AppColors.textSecondary, height: 1.35))),
                  ],
                ),
              ),
            const Divider(height: 24),
            Text(result.sourceSummary,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11)),
            const SizedBox(height: 3),
            Text('Updated ${_formatTime(result.calculatedAt)}',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11)),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: () => launchUrl(
                Uri.parse('https://open-meteo.com/'),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new_rounded, size: 14),
              label: const Text('Weather data by Open-Meteo'),
            ),
          ],
        ),
      );

  String _formatTime(DateTime value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${value.hour >= 12 ? 'PM' : 'AM'}';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(top: 42),
        child: Column(
          children: [
            Icon(Icons.analytics_outlined, size: 54, color: AppColors.gold),
            SizedBox(height: 14),
            Text('Choose two stations to begin',
                style: TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
      );
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 48, color: AppColors.textSecondary),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
}
