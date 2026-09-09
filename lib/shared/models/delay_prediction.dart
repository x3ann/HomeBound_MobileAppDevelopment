class DelayPrediction {
  final int riskScore;
  final int expectedDelayMinutes;
  final String riskLevel;
  final String confidence;
  final String weatherSummary;
  final String serviceSummary;
  final String estimatedArrival;
  final List<String> factors;
  final String sourceSummary;
  final DateTime calculatedAt;

  const DelayPrediction({
    required this.riskScore,
    required this.expectedDelayMinutes,
    required this.riskLevel,
    required this.confidence,
    required this.weatherSummary,
    required this.serviceSummary,
    required this.estimatedArrival,
    required this.factors,
    required this.sourceSummary,
    required this.calculatedAt,
  });
}

class CurrentWeather {
  final double precipitationMm;
  final int weatherCode;
  final bool isLive;

  const CurrentWeather({
    required this.precipitationMm,
    required this.weatherCode,
    required this.isLive,
  });

  String get summary {
    if (!isLive) return 'Weather unavailable';
    if (precipitationMm >= 7.5) return 'Heavy rain';
    if (precipitationMm >= 2.5) return 'Moderate rain';
    if (precipitationMm > 0) return 'Light rain';
    if (weatherCode >= 95) return 'Thunderstorm';
    if (weatherCode >= 51) return 'Rain possible';
    if (weatherCode >= 45) return 'Foggy';
    if (weatherCode >= 1) return 'Partly cloudy';
    return 'Clear';
  }
}
