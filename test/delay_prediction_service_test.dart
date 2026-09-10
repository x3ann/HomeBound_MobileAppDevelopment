import 'package:flutter_test/flutter_test.dart';
import 'package:homebound/services/delay_prediction_service.dart';
import 'package:homebound/shared/models/delay_prediction.dart';
import 'package:homebound/shared/models/route_model.dart';
import 'package:homebound/shared/models/stop.dart';
import 'package:homebound/shared/theme/app_theme.dart';
import 'package:latlong2/latlong.dart';

void main() {
  const origin = Stop(
    name: 'Origin',
    platform: 'Rail station',
    position: LatLng(3.1, 101.6),
    timeToDeparture: Duration(minutes: 6),
    urgency: ServiceUrgency.onTime,
  );
  const route = RouteOption(
    departureTime: '8:00 PM',
    mode: 'Rapid Rail',
    etaSummary: 'Arrives 8:20 PM',
    status: ServiceUrgency.onTime,
    totalMinutes: 20,
  );

  test('delay estimate is deterministic for the same official inputs', () {
    final time = DateTime(2026, 9, 9, 20);
    final first = DelayPredictionService.calculate(
      origin: origin,
      routes: const [route],
      weather: const CurrentWeather(
          precipitationMm: 0, weatherCode: 0, isLive: true),
      scheduleAvailable: true,
      calculatedAt: time,
    );
    final second = DelayPredictionService.calculate(
      origin: origin,
      routes: const [route],
      weather: const CurrentWeather(
          precipitationMm: 0, weatherCode: 0, isLive: true),
      scheduleAvailable: true,
      calculatedAt: time,
    );

    expect(second.riskScore, first.riskScore);
    expect(second.expectedDelayMinutes, first.expectedDelayMinutes);
    expect(first.confidence, 'Medium');
    expect(first.riskScore, isNot(8));
    expect(first.totalEstimatedMinutes, 20);
  });

  test('heavy rain increases risk and estimated delay', () {
    final clear = DelayPredictionService.calculate(
      origin: origin,
      routes: const [route],
      weather: const CurrentWeather(
          precipitationMm: 0, weatherCode: 0, isLive: true),
      scheduleAvailable: true,
      calculatedAt: DateTime(2026, 9, 9),
    );
    final rainy = DelayPredictionService.calculate(
      origin: origin,
      routes: const [route],
      weather: const CurrentWeather(
          precipitationMm: 9, weatherCode: 65, isLive: true),
      scheduleAvailable: true,
      calculatedAt: DateTime(2026, 9, 9),
    );

    expect(rainy.riskScore, greaterThan(clear.riskScore));
    expect(rainy.expectedDelayMinutes, greaterThan(clear.expectedDelayMinutes));
  });
}
