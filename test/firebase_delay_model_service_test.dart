import 'package:flutter_test/flutter_test.dart';
import 'package:homebound/services/firebase_delay_model_service.dart';
import 'package:homebound/shared/models/delay_prediction.dart';

void main() {
  Map<String, dynamic> modelData() => {
        'status': 'active',
        'schemaVersion': 1,
        'scope': 'bus',
        'version': 'bus-delay-test',
        'featureNames': [
          'precipitation_mm',
          'hour_sin',
          'hour_cos',
          'weekday_sin',
          'weekday_cos',
          'is_feeder',
        ],
        'intercept': 1.0,
        'weights': [2.0, 0.0, 0.0, 0.0, 0.0, 0.5],
        'means': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        'scales': [1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
        'minimumMinutes': -3.0,
        'maximumMinutes': 15.0,
        'sampleCount': 1400,
        'validationMae': 1.2,
      };

  test('loads a validated model and calculates its feature vector', () {
    final model = TransitDelayModel.fromMap(modelData());
    final estimate = model.predict(
      weather: const CurrentWeather(
        precipitationMm: 2,
        weatherCode: 61,
        isLive: true,
      ),
      calculatedAt: DateTime.utc(2026, 9, 10, 4),
      isFeeder: true,
    );
    expect(estimate, 5.5);
  });

  test('rejects an unvalidated candidate', () {
    final data = modelData()..['status'] = 'candidate';
    expect(() => TransitDelayModel.fromMap(data), throwsFormatException);
  });

  test('rejects mismatched model arrays', () {
    final data = modelData()..['weights'] = [1.0];
    expect(() => TransitDelayModel.fromMap(data), throwsFormatException);
  });
}
