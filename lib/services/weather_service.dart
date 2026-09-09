import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../shared/models/delay_prediction.dart';

class WeatherService {
  WeatherService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<CurrentWeather> currentAt(LatLng position) async {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': position.latitude.toStringAsFixed(5),
      'longitude': position.longitude.toStringAsFixed(5),
      'current': 'precipitation,weather_code',
      'timezone': 'Asia/Kuala_Lumpur',
    });
    final response =
        await _client.get(uri).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw http.ClientException(
          'Weather service returned ${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final current = body['current'] as Map<String, dynamic>?;
    if (current == null) throw const FormatException('Missing current weather');
    return CurrentWeather(
      precipitationMm: (current['precipitation'] as num?)?.toDouble() ?? 0,
      weatherCode: (current['weather_code'] as num?)?.toInt() ?? 0,
      isLive: true,
    );
  }
}
