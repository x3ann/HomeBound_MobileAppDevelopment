import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:csv/csv.dart';
import 'package:http/http.dart' as http;
import 'gtfs_models.dart';

/// Client for Malaysia's official Open API GTFS Static feed.
///
/// Docs: https://developer.data.gov.my/realtime-api/gtfs-static
/// No API key required. Returns a ZIP of standard GTFS text files
/// (stops.txt, routes.txt, trips.txt, stop_times.txt, calendar.txt).
///
/// `category` for the Prasarana endpoint (LRT/MRT/monorail/bus) is one of:
/// rapid-rail-kl, rapid-bus-kl, rapid-bus-mrtfeeder, rapid-bus-penang,
/// rapid-bus-kuantan. `rapid-rail-kl` covers LRT/MRT/monorail.
class GtfsService {
  static const _baseUrl = 'https://api.data.gov.my/gtfs-static/prasarana';
  static const _timeout = Duration(seconds: 20);
  static final Map<String, Future<Archive>> _archiveCache = {};

  /// Invalidates a downloaded feed so a manual refresh performs a new request.
  static void clearCache({String category = 'rapid-rail-kl'}) {
    _archiveCache.remove(category);
  }

  /// Fetches and parses stops.txt for the given Prasarana category.
  /// Throws on any network/parse failure — callers should catch and fall
  /// back to cached/mock data rather than let this bubble up to the UI.
  static Future<List<GtfsStop>> fetchStops(
      {String category = 'rapid-rail-kl'}) async {
    final rows = await _fetchCsvFile(category: category, fileName: 'stops.txt');
    if (rows.isEmpty) return [];

    final header =
        rows.first.map((h) => h.toString().trim().toLowerCase()).toList();
    final idIdx = header.indexOf('stop_id');
    final nameIdx = header.indexOf('stop_name');
    final latIdx = header.indexOf('stop_lat');
    final lonIdx = header.indexOf('stop_lon');
    if (idIdx < 0 || nameIdx < 0 || latIdx < 0 || lonIdx < 0) {
      throw const FormatException('stops.txt missing expected GTFS columns');
    }

    final stops = <GtfsStop>[];
    for (final row in rows.skip(1)) {
      if (row.length <=
          [idIdx, nameIdx, latIdx, lonIdx].reduce((a, b) => a > b ? a : b)) {
        continue; // malformed row, skip
      }
      final lat = double.tryParse(row[latIdx].toString());
      final lon = double.tryParse(row[lonIdx].toString());
      if (lat == null || lon == null) continue;
      stops.add(GtfsStop(
        stopId: row[idIdx].toString(),
        name: row[nameIdx].toString().trim(),
        lat: lat,
        lon: lon,
      ));
    }
    return stops;
  }

  /// Fetches and parses routes.txt for the given Prasarana category.
  static Future<List<GtfsRoute>> fetchRoutes(
      {String category = 'rapid-rail-kl'}) async {
    final rows =
        await _fetchCsvFile(category: category, fileName: 'routes.txt');
    if (rows.isEmpty) return [];

    final header =
        rows.first.map((h) => h.toString().trim().toLowerCase()).toList();
    final idIdx = header.indexOf('route_id');
    final shortIdx = header.indexOf('route_short_name');
    final longIdx = header.indexOf('route_long_name');
    if (idIdx < 0) {
      throw const FormatException('routes.txt missing route_id column');
    }

    final routes = <GtfsRoute>[];
    for (final row in rows.skip(1)) {
      if (row.length <= idIdx) {
        continue;
      }
      routes.add(GtfsRoute(
        routeId: row[idIdx].toString(),
        shortName: shortIdx >= 0 && row.length > shortIdx
            ? row[shortIdx].toString()
            : '',
        longName:
            longIdx >= 0 && row.length > longIdx ? row[longIdx].toString() : '',
      ));
    }
    return routes;
  }

  /// Fetches and parses trips.txt for the given Prasarana category.
  static Future<List<GtfsTrip>> fetchTrips(
      {String category = 'rapid-rail-kl'}) async {
    final rows = await _fetchCsvFile(category: category, fileName: 'trips.txt');
    if (rows.isEmpty) return [];

    final header =
        rows.first.map((h) => h.toString().trim().toLowerCase()).toList();
    final tripIdx = header.indexOf('trip_id');
    final routeIdx = header.indexOf('route_id');
    final serviceIdx = header.indexOf('service_id');
    if (tripIdx < 0 || routeIdx < 0 || serviceIdx < 0) {
      throw const FormatException('trips.txt missing expected GTFS columns');
    }

    final trips = <GtfsTrip>[];
    for (final row in rows.skip(1)) {
      final maxIdx =
          [tripIdx, routeIdx, serviceIdx].reduce((a, b) => a > b ? a : b);
      if (row.length <= maxIdx) continue;
      trips.add(GtfsTrip(
        tripId: row[tripIdx].toString(),
        routeId: row[routeIdx].toString(),
        serviceId: row[serviceIdx].toString(),
      ));
    }
    return trips;
  }

  /// Fetches repeating trip windows used by the rail feed to describe
  /// frequent service without listing every departure as a separate trip.
  static Future<List<GtfsFrequency>> fetchFrequencies(
      {String category = 'rapid-rail-kl'}) async {
    List<List<dynamic>> rows;
    try {
      rows =
          await _fetchCsvFile(category: category, fileName: 'frequencies.txt');
    } on FormatException {
      return const [];
    }
    if (rows.isEmpty) return const [];
    final header =
        rows.first.map((h) => h.toString().trim().toLowerCase()).toList();
    final tripIdx = header.indexOf('trip_id');
    final startIdx = header.indexOf('start_time');
    final endIdx = header.indexOf('end_time');
    final headwayIdx = header.indexOf('headway_secs');
    if (tripIdx < 0 || startIdx < 0 || endIdx < 0 || headwayIdx < 0) {
      throw const FormatException(
          'frequencies.txt missing expected GTFS columns');
    }
    final frequencies = <GtfsFrequency>[];
    for (final row in rows.skip(1)) {
      final maxIdx = [tripIdx, startIdx, endIdx, headwayIdx]
          .reduce((a, b) => a > b ? a : b);
      if (row.length <= maxIdx) continue;
      final headway = int.tryParse(row[headwayIdx].toString());
      if (headway == null || headway <= 0) continue;
      frequencies.add(GtfsFrequency(
        tripId: row[tripIdx].toString(),
        startTime: row[startIdx].toString().trim(),
        endTime: row[endIdx].toString().trim(),
        headwaySeconds: headway,
      ));
    }
    return frequencies;
  }

  /// Fetches and parses calendar.txt for the given Prasarana category.
  static Future<List<GtfsCalendarService>> fetchCalendar(
      {String category = 'rapid-rail-kl'}) async {
    final rows =
        await _fetchCsvFile(category: category, fileName: 'calendar.txt');
    if (rows.isEmpty) return [];

    final header =
        rows.first.map((h) => h.toString().trim().toLowerCase()).toList();
    final serviceIdx = header.indexOf('service_id');
    final dayIdx = {
      for (final day in [
        'monday',
        'tuesday',
        'wednesday',
        'thursday',
        'friday',
        'saturday',
        'sunday',
      ])
        day: header.indexOf(day),
    };
    final startIdx = header.indexOf('start_date');
    final endIdx = header.indexOf('end_date');
    if (serviceIdx < 0) {
      throw const FormatException('calendar.txt missing service_id column');
    }

    bool dayFlag(List<dynamic> row, String day) {
      final idx = dayIdx[day]!;
      if (idx < 0 || row.length <= idx) return false;
      return row[idx].toString().trim() == '1';
    }

    final services = <GtfsCalendarService>[];
    for (final row in rows.skip(1)) {
      if (row.length <= serviceIdx) continue;
      services.add(GtfsCalendarService(
        serviceId: row[serviceIdx].toString(),
        monday: dayFlag(row, 'monday'),
        tuesday: dayFlag(row, 'tuesday'),
        wednesday: dayFlag(row, 'wednesday'),
        thursday: dayFlag(row, 'thursday'),
        friday: dayFlag(row, 'friday'),
        saturday: dayFlag(row, 'saturday'),
        sunday: dayFlag(row, 'sunday'),
        startDate: startIdx >= 0 && row.length > startIdx
            ? row[startIdx].toString()
            : '',
        endDate:
            endIdx >= 0 && row.length > endIdx ? row[endIdx].toString() : '',
      ));
    }
    return services;
  }

  /// Fetches holiday and other service-day overrides. Some feeds omit this
  /// optional GTFS file, in which case there are simply no overrides.
  static Future<List<GtfsCalendarDate>> fetchCalendarDates(
      {String category = 'rapid-rail-kl'}) async {
    List<List<dynamic>> rows;
    try {
      rows = await _fetchCsvFile(
          category: category, fileName: 'calendar_dates.txt');
    } on FormatException {
      return const [];
    }
    if (rows.isEmpty) return const [];
    final header =
        rows.first.map((h) => h.toString().trim().toLowerCase()).toList();
    final serviceIdx = header.indexOf('service_id');
    final dateIdx = header.indexOf('date');
    final exceptionIdx = header.indexOf('exception_type');
    if (serviceIdx < 0 || dateIdx < 0 || exceptionIdx < 0) {
      throw const FormatException(
          'calendar_dates.txt missing expected GTFS columns');
    }
    final dates = <GtfsCalendarDate>[];
    for (final row in rows.skip(1)) {
      final maxIdx =
          [serviceIdx, dateIdx, exceptionIdx].reduce((a, b) => a > b ? a : b);
      if (row.length <= maxIdx) continue;
      final exceptionType = int.tryParse(row[exceptionIdx].toString());
      if (exceptionType != 1 && exceptionType != 2) continue;
      dates.add(GtfsCalendarDate(
        serviceId: row[serviceIdx].toString(),
        date: row[dateIdx].toString(),
        exceptionType: exceptionType!,
      ));
    }
    return dates;
  }

  /// Fetches and parses stop_times.txt for the given Prasarana category.
  /// This is the file that actually lets us compute a real "next
  /// departure" and "last service" per stop — stops.txt alone only has
  /// station geography, not schedules.
  static Future<List<GtfsStopTime>> fetchStopTimes(
      {String category = 'rapid-rail-kl'}) async {
    final rows =
        await _fetchCsvFile(category: category, fileName: 'stop_times.txt');
    if (rows.isEmpty) return [];

    final header =
        rows.first.map((h) => h.toString().trim().toLowerCase()).toList();
    final tripIdx = header.indexOf('trip_id');
    final stopIdx = header.indexOf('stop_id');
    final arrIdx = header.indexOf('arrival_time');
    final depIdx = header.indexOf('departure_time');
    final seqIdx = header.indexOf('stop_sequence');
    if (tripIdx < 0 || stopIdx < 0 || arrIdx < 0 || depIdx < 0) {
      throw const FormatException(
          'stop_times.txt missing expected GTFS columns');
    }

    final stopTimes = <GtfsStopTime>[];
    for (final row in rows.skip(1)) {
      final maxIdx =
          [tripIdx, stopIdx, arrIdx, depIdx].reduce((a, b) => a > b ? a : b);
      if (row.length <= maxIdx) continue;
      stopTimes.add(GtfsStopTime(
        tripId: row[tripIdx].toString(),
        stopId: row[stopIdx].toString(),
        arrivalTime: row[arrIdx].toString().trim(),
        departureTime: row[depIdx].toString().trim(),
        stopSequence: seqIdx >= 0 && row.length > seqIdx
            ? int.tryParse(row[seqIdx].toString()) ?? 0
            : 0,
      ));
    }
    return stopTimes;
  }

  /// Converts a GTFS time string ("HH:MM:SS") to seconds since midnight
  /// of the *service day*. GTFS deliberately allows hours >= 24 for trips
  /// that run past midnight, so this does not wrap — callers that need a
  /// wall-clock string should use [formatSecondsAsClock].
  static int? gtfsTimeToSeconds(String time) {
    final parts = time.split(':');
    if (parts.length != 3) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final s = int.tryParse(parts[2]);
    if (h == null || m == null || s == null) return null;
    return h * 3600 + m * 60 + s;
  }

  /// Formats seconds-since-midnight (GTFS style, may exceed 86400) as a
  /// 12-hour clock string, e.g. 90000 -> "1:00 AM" (past-midnight wrap).
  static String formatSecondsAsClock(int totalSeconds) {
    final wrapped = totalSeconds % 86400;
    final hour24 = wrapped ~/ 3600;
    final minute = (wrapped % 3600) ~/ 60;
    final period = hour24 >= 12 ? 'PM' : 'AM';
    var hour12 = hour24 % 12;
    if (hour12 == 0) hour12 = 12;
    return '$hour12:${minute.toString().padLeft(2, '0')} $period';
  }

  /// Downloads the GTFS ZIP for [category], extracts [fileName], and
  /// parses it as CSV. Returns rows including the header row.
  static Future<List<List<dynamic>>> _fetchCsvFile({
    required String category,
    required String fileName,
  }) async {
    final archive = await _archiveFor(category);
    final file = archive.files.firstWhere(
      (f) => f.name.toLowerCase() == fileName.toLowerCase(),
      orElse: () => throw FormatException(
          '$fileName not found in GTFS feed for $category'),
    );

    final content =
        utf8.decode(file.content as List<int>, allowMalformed: true);
    return const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
        .convert(content);
  }

  static Future<Archive> _archiveFor(String category) {
    return _archiveCache.putIfAbsent(category, () async {
      final uri = Uri.parse('$_baseUrl?category=$category');
      try {
        final response = await http.get(uri).timeout(_timeout);
        if (response.statusCode != 200) {
          throw http.ClientException(
              'GTFS Static API returned ${response.statusCode}', uri);
        }
        return ZipDecoder().decodeBytes(response.bodyBytes);
      } catch (_) {
        _archiveCache.remove(category);
        rethrow;
      }
    });
  }
}
