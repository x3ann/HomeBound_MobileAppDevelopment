import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';

import '../shared/models/delay_prediction.dart';

class DelayModelEstimate {
  final double expectedDelayMinutes;
  final String version;
  final int sampleCount;
  final double validationMae;

  const DelayModelEstimate({
    required this.expectedDelayMinutes,
    required this.version,
    required this.sampleCount,
    required this.validationMae,
  });
}

class TransitDelayModel {
  final String version;
  final String scope;
  final List<String> featureNames;
  final double intercept;
  final List<double> weights;
  final List<double> means;
  final List<double> scales;
  final double minimumMinutes;
  final double maximumMinutes;
  final int sampleCount;
  final double validationMae;

  const TransitDelayModel({
    required this.version,
    required this.scope,
    required this.featureNames,
    required this.intercept,
    required this.weights,
    required this.means,
    required this.scales,
    required this.minimumMinutes,
    required this.maximumMinutes,
    required this.sampleCount,
    required this.validationMae,
  });

  factory TransitDelayModel.fromMap(Map<String, dynamic> data) {
    List<double> numbers(String key) =>
        (data[key] as List<dynamic>? ?? const [])
            .map((value) => (value as num).toDouble())
            .toList(growable: false);

    final featureNames = (data['featureNames'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .toList(growable: false);
    final weights = numbers('weights');
    final means = numbers('means');
    final scales = numbers('scales');
    if (data['status'] != 'active' ||
        data['schemaVersion'] != 1 ||
        data['scope'] != 'bus' ||
        featureNames.isEmpty ||
        weights.length != featureNames.length ||
        means.length != featureNames.length ||
        scales.length != featureNames.length ||
        scales.any((value) => value <= 0)) {
      throw const FormatException('Invalid transit delay model');
    }
    return TransitDelayModel(
      version: data['version'].toString(),
      scope: data['scope'].toString(),
      featureNames: featureNames,
      intercept: (data['intercept'] as num).toDouble(),
      weights: weights,
      means: means,
      scales: scales,
      minimumMinutes: (data['minimumMinutes'] as num).toDouble(),
      maximumMinutes: (data['maximumMinutes'] as num).toDouble(),
      sampleCount: (data['sampleCount'] as num).toInt(),
      validationMae: (data['validationMae'] as num).toDouble(),
    );
  }

  double predict({
    required CurrentWeather weather,
    required DateTime calculatedAt,
    required bool isFeeder,
  }) {
    final malaysiaTime = calculatedAt.toUtc().add(const Duration(hours: 8));
    final hour = malaysiaTime.hour + malaysiaTime.minute / 60;
    final weekday = malaysiaTime.weekday % 7;
    final values = <String, double>{
      'precipitation_mm': weather.precipitationMm.clamp(0, 50),
      'hour_sin': math.sin(2 * math.pi * hour / 24),
      'hour_cos': math.cos(2 * math.pi * hour / 24),
      'weekday_sin': math.sin(2 * math.pi * weekday / 7),
      'weekday_cos': math.cos(2 * math.pi * weekday / 7),
      'is_feeder': isFeeder ? 1 : 0,
    };
    var result = intercept;
    for (var index = 0; index < featureNames.length; index++) {
      final value = values[featureNames[index]];
      if (value == null) throw const FormatException('Unknown model feature');
      result += weights[index] * ((value - means[index]) / scales[index]);
    }
    return result.clamp(minimumMinutes, maximumMinutes);
  }
}

class FirebaseDelayModelService {
  FirebaseDelayModelService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;
  TransitDelayModel? _cachedModel;
  DateTime? _cacheTime;

  Future<DelayModelEstimate?> estimate({
    required CurrentWeather weather,
    required DateTime calculatedAt,
    required String transportDescription,
  }) async {
    final description = transportDescription.toLowerCase();
    if (!description.contains('bus')) return null;
    final model = await _loadModel();
    if (model == null) return null;
    final minutes = model.predict(
      weather: weather,
      calculatedAt: calculatedAt,
      isFeeder: description.contains('feeder'),
    );
    return DelayModelEstimate(
      expectedDelayMinutes: math.max(0, minutes),
      version: model.version,
      sampleCount: model.sampleCount,
      validationMae: model.validationMae,
    );
  }

  Future<TransitDelayModel?> _loadModel() async {
    final now = DateTime.now();
    if (_cachedModel != null &&
        _cacheTime != null &&
        now.difference(_cacheTime!) < const Duration(hours: 1)) {
      return _cachedModel;
    }
    try {
      final snapshot = await _firestore
          .collection('delayModels')
          .doc('current')
          .get(const GetOptions(source: Source.serverAndCache));
      final data = snapshot.data();
      if (data == null) return null;
      final model = TransitDelayModel.fromMap(data);
      _cachedModel = model;
      _cacheTime = now;
      return model;
    } catch (_) {
      return null;
    }
  }
}
