import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/delay_prediction_service.dart';
import '../../services/bus_arrival_service.dart';
import '../../services/transit_repository.dart';
import '../../shared/models/delay_prediction.dart';
import '../../shared/models/route_model.dart';
import '../../shared/models/stop.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/data_source_badge.dart';

class AiDelayPredictionScreen extends StatefulWidget {
  final void Function(Stop origin, Stop destination)? onGoNow;

  const AiDelayPredictionScreen({super.key, this.onGoNow});

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
  String _fromMode = 'All';
  String _toMode = 'All';
  String? _fromLine;
  String? _toLine;

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
      final groups = await Future.wait<List<Stop>>([
        _repository.getStationDirectory(),
        BusArrivalService.instance
            .scheduledStops(category: 'rapid-bus-kl')
            .catchError((_) => <Stop>[]),
        BusArrivalService.instance
            .scheduledStops(category: 'rapid-bus-mrtfeeder')
            .catchError((_) => <Stop>[]),
      ]);
      final unique = <String, Stop>{};
      for (final station in groups.expand((group) => group)) {
        unique.putIfAbsent(
          '${station.transportMode}|${station.gtfsStopId ?? station.name}|${station.routeLabel}',
          () => station,
        );
      }
      final stations = unique.values.toList()
        ..sort((a, b) {
          final byMode = a.transportMode.compareTo(b.transportMode);
          return byMode != 0 ? byMode : a.name.compareTo(b.name);
        });
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
        _loadError = 'Unable to load the official stop directory.';
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
    if (origin.gtfsStopId == destination.gtfsStopId &&
        origin.transportMode == destination.transportMode) {
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
      final previousMode = _fromMode;
      _fromMode = _toMode;
      _toMode = previousMode;
      final previousLine = _fromLine;
      _fromLine = _toLine;
      _toLine = previousLine;
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
                        'Uses a validated bus model when available, with official schedules and current weather as the fallback. Rail results remain schedule-based until stable realtime rail data is published.',
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
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _fromStation == null ||
                                    _toStation == null ||
                                    widget.onGoNow == null
                                ? null
                                : () => widget.onGoNow!(
                                      _fromStation!,
                                      _toStation!,
                                    ),
                            icon: const Icon(Icons.directions_rounded),
                            label: const Text('Go now · view directions'),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _detailsCard(prediction),
                      ],
                    ],
                  ),
      ),
    );
  }

  Widget _routeSelector() {
    final fromStations = _filteredStations(_fromMode, _fromLine);
    final toStations = _filteredStations(_toMode, _toLine);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          _filterRow(
            label: 'FROM SERVICE',
            mode: _fromMode,
            line: _fromLine,
            onModeChanged: (value) => setState(() {
              _fromMode = value;
              _fromLine = null;
              _fromStation = null;
              _prediction = null;
            }),
            onLineChanged: (value) => setState(() {
              _fromLine = value;
              _fromStation = null;
              _prediction = null;
            }),
          ),
          const SizedBox(height: 12),
          _stationDropdown(
            label: 'FROM',
            value: _fromStation,
            hint: 'Select origin station',
            stations: fromStations,
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
          _filterRow(
            label: 'TO SERVICE',
            mode: _toMode,
            line: _toLine,
            onModeChanged: (value) => setState(() {
              _toMode = value;
              _toLine = null;
              _toStation = null;
              _prediction = null;
            }),
            onLineChanged: (value) => setState(() {
              _toLine = value;
              _toStation = null;
              _prediction = null;
            }),
          ),
          const SizedBox(height: 12),
          _stationDropdown(
            label: 'TO',
            value: _toStation,
            hint: 'Select destination station',
            stations: toStations,
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
                  : RouteOption.formatMinutes(result.totalEstimatedMinutes),
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

  List<Stop> _filteredStations(String mode, String? line) =>
      _stations.where((station) {
        final modeMatches = mode == 'All' ||
            station.transportMode.toLowerCase().contains(mode.toLowerCase());
        final lineMatches = line == null ||
            station.routeLabel.toLowerCase().contains(line.toLowerCase());
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

  List<String> _lineOptions(String mode) {
    final values = <String>{};
    for (final station in _stations) {
      if (mode != 'All' &&
          !station.transportMode.toLowerCase().contains(mode.toLowerCase())) {
        continue;
      }
      values.addAll(station.routeLabel
          .split(' · ')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty));
    }
    return values.toList()..sort();
  }

  Widget _modeDropdown({
    required String value,
    required ValueChanged<String> onChanged,
  }) =>
      DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Transport type'),
        items: _modeOptions
            .map((mode) => DropdownMenuItem(value: mode, child: Text(mode)))
            .toList(),
        onChanged: (mode) => onChanged(mode ?? 'All'),
      );

  Widget _lineDropdown({
    required String mode,
    required String? value,
    required ValueChanged<String?> onChanged,
  }) =>
      DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Line'),
        hint: const Text('All lines'),
        items: [
          const DropdownMenuItem<String>(value: null, child: Text('All lines')),
          ..._lineOptions(mode).map(
            (line) => DropdownMenuItem(
                value: line,
                child: Text(
                  line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )),
          ),
        ],
        onChanged: onChanged,
      );

  Widget _filterRow({
    required String label,
    required String mode,
    required String? line,
    required ValueChanged<String> onModeChanged,
    required ValueChanged<String?> onLineChanged,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .9)),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                  child: _modeDropdown(value: mode, onChanged: onModeChanged)),
              const SizedBox(width: 10),
              Expanded(
                  child: _lineDropdown(
                      mode: mode, value: line, onChanged: onLineChanged)),
            ],
          ),
        ],
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
