import '../shared/models/delay_prediction.dart';
import '../shared/models/route_model.dart';
import '../shared/models/stop.dart';
import 'transit_repository.dart';
import 'weather_service.dart';

class DelayPredictionService {
  DelayPredictionService({
    TransitRepository? repository,
    WeatherService? weatherService,
  })  : _repository = repository ?? TransitRepository.instance,
        _weatherService = weatherService ?? WeatherService();

  final TransitRepository _repository;
  final WeatherService _weatherService;

  Future<DelayPrediction> predict({
    required Stop origin,
    required Stop destination,
  }) async {
    final results = await Future.wait<Object?>([
      _repository.getNearbyStops(),
      _repository.planRouteBetweenStops(origin, destination),
      _weatherService.currentAt(origin.position).catchError(
            (_) => const CurrentWeather(
              precipitationMm: 0,
              weatherCode: 0,
              isLive: false,
            ),
          ),
    ]);
    final lookup = results[0] as TransitLookupResult;
    final routes = results[1] as List<RouteOption>;
    final weather = results[2] as CurrentWeather;
    final currentOrigin = lookup.stops.firstWhere(
      (stop) => stop.gtfsStopId == origin.gtfsStopId,
      orElse: () => origin,
    );
    return calculate(
      origin: currentOrigin,
      destination: destination,
      routes: routes,
      weather: weather,
      scheduleAvailable: lookup.source != TransitDataSource.unavailable,
      calculatedAt: DateTime.now(),
    );
  }

  static DelayPrediction calculate({
    required Stop origin,
    required Stop destination,
    required List<RouteOption> routes,
    required CurrentWeather weather,
    required bool scheduleAvailable,
    required DateTime calculatedAt,
  }) {
    var score = 0;
    var delayMinutes = 0;
    final factors = <String>[];

    if (!scheduleAvailable || routes.isEmpty) {
      score += 50;
      factors.add('No usable scheduled route is currently available.');
    } else {
      factors.add('An official scheduled route is available.');
      final transfers = routes.first.transferCount;
      if (transfers > 0) {
        score += transfers * 7;
        delayMinutes += transfers * 2;
        factors.add(
            '$transfers transfer${transfers == 1 ? '' : 's'} adds connection risk.');
      }
      final originModes = origin.transportMode
          .split('/')
          .map((value) => value.trim().toLowerCase())
          .toSet();
      final destinationModes = destination.transportMode
          .split('/')
          .map((value) => value.trim().toLowerCase())
          .toSet();
      if (originModes.intersection(destinationModes).isEmpty) {
        score += 7;
        delayMinutes += 2;
        factors.add(
            'This journey switches from ${origin.transportMode} to ${destination.transportMode}.');
      }
      final originLines = origin.routeLabel.split(' · ').toSet()
        ..removeWhere((value) => value.isEmpty);
      final destinationLines = destination.routeLabel.split(' · ').toSet()
        ..removeWhere((value) => value.isEmpty);
      if (originLines.isNotEmpty &&
          destinationLines.isNotEmpty &&
          originLines.intersection(destinationLines).isEmpty) {
        score += 6;
        delayMinutes += 2;
        factors.add('A line interchange adds extra platform and waiting time.');
      }
    }

    final waitMinutes = origin.timeToDeparture.inMinutes;
    if (origin.timeToDeparture <= Duration.zero) {
      score += 32;
      factors.add('No further departure is listed for the origin today.');
    } else if (waitMinutes >= 20) {
      score += 24;
      delayMinutes += 5;
      factors.add('The next scheduled departure is $waitMinutes minutes away.');
    } else if (waitMinutes >= 10) {
      score += 12;
      delayMinutes += 2;
      factors.add('The next scheduled departure is $waitMinutes minutes away.');
    } else {
      score += (waitMinutes / 2).round().clamp(0, 10);
      factors.add('The next scheduled departure is due within 10 minutes.');
    }

    if (weather.isLive) {
      final rain = weather.precipitationMm;
      if (rain >= 7.5) {
        score += 34;
        delayMinutes += 8;
        factors.add('Current heavy rain can slow road access and transfers.');
      } else if (rain >= 2.5) {
        score += 22;
        delayMinutes += 5;
        factors.add('Current moderate rain can affect access and transfers.');
      } else if (rain > 0) {
        score += 10;
        delayMinutes += 2;
        factors.add('Light rain is currently reported near the origin.');
      } else {
        factors.add('No current precipitation is reported near the origin.');
      }
    } else {
      factors.add('Live weather was unavailable and was not guessed.');
    }

    score = score.clamp(0, 100);
    final level = score >= 70
        ? 'HIGH RISK'
        : score >= 35
            ? 'MEDIUM RISK'
            : 'LOW RISK';
    final confidence = scheduleAvailable && weather.isLive
        ? 'Medium'
        : scheduleAvailable
            ? 'Low–medium'
            : 'Low';
    return DelayPrediction(
      riskScore: score,
      expectedDelayMinutes: delayMinutes,
      riskLevel: level,
      confidence: confidence,
      weatherSummary: weather.summary,
      serviceSummary: routes.isEmpty
          ? 'No route found'
          : '${routes.first.totalMinutes} min · ${routes.first.transferCount} transfer${routes.first.transferCount == 1 ? '' : 's'}',
      estimatedArrival: routes.isEmpty
          ? 'Unavailable'
          : (routes.first.arrivalTime.isNotEmpty
              ? (delayMinutes == 0
                  ? routes.first.arrivalTime
                  : '${routes.first.arrivalTime} + up to $delayMinutes min')
              : routes.first.etaSummary),
      totalEstimatedMinutes:
          routes.isEmpty ? 0 : routes.first.totalMinutes + delayMinutes,
      factors: factors,
      sourceSummary: weather.isLive
          ? 'Official GTFS schedule + current Open-Meteo weather'
          : 'Official GTFS schedule; live weather unavailable',
      calculatedAt: calculatedAt,
    );
  }
}
