import 'dart:convert';

import 'package:http/http.dart' as http;

class RailEstimate {
  final String text;
  const RailEstimate(this.text);
}

/// Optional PULSE-derived rail estimates. This is a third-party reverse proxy,
/// so failures never replace the official GTFS schedule shown by the app.
class ExperimentalRailService {
  ExperimentalRailService._();
  static final instance = ExperimentalRailService._();
  static const _base = 'https://api.samsam123.name.my/pulse-rapidkl';

  Future<RailEstimate?> estimateForStop(String stopId) async {
    final route =
        RegExp(r'^[A-Za-z]+').firstMatch(stopId)?.group(0)?.toUpperCase();
    if (route == null || route.isEmpty) return null;
    for (final direction in const ['0', '1']) {
      try {
        final uri =
            Uri.parse('$_base/trainfrequency.php').replace(queryParameters: {
          'routeid': route,
          'directionid': direction,
          'stopid': stopId,
        });
        final response =
            await http.get(uri).timeout(const Duration(seconds: 6));
        if (response.statusCode != 200) continue;
        final decoded = jsonDecode(response.body);
        final candidates = <String>[];
        _collectStrings(decoded, candidates);
        final useful = candidates.firstWhere(
          (value) =>
              RegExp(r'(min|minute|arrival|frequency)', caseSensitive: false)
                  .hasMatch(value),
          orElse: () => '',
        );
        if (useful.isNotEmpty) return RailEstimate(useful);
      } catch (_) {
        // Official scheduled GTFS remains the fallback.
      }
    }
    return null;
  }

  void _collectStrings(Object? value, List<String> output) {
    if (value is String) output.add(value);
    if (value is List) {
      for (final item in value) _collectStrings(item, output);
    }
    if (value is Map) {
      for (final item in value.values) _collectStrings(item, output);
    }
  }
}
