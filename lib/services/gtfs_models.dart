/// A single row from GTFS `stops.txt` — one physical transit stop/station.
class GtfsStop {
  final String stopId;
  final String name;
  final double lat;
  final double lon;

  const GtfsStop({
    required this.stopId,
    required this.name,
    required this.lat,
    required this.lon,
  });
}

/// A single row from GTFS `routes.txt` — one bus/rail line.
class GtfsRoute {
  final String routeId;
  final String shortName;
  final String longName;
  final int? routeType;

  const GtfsRoute({
    required this.routeId,
    required this.shortName,
    required this.longName,
    this.routeType,
  });

  String get displayName {
    final short = shortName.trim();
    final long = longName.trim();
    if (short.isNotEmpty && long.isNotEmpty && short != long) {
      return '$short — $long';
    }
    return short.isNotEmpty ? short : long;
  }

  String get modeLabel {
    final text = '$shortName $longName'.toUpperCase();
    if (text.contains('BRT')) return 'BRT';
    if (routeType == 3 || text.contains('BUS')) return 'Bus';
    if (routeType == 12 || text.contains('MONORAIL') || text.contains('MRL')) {
      return 'Monorail';
    }
    if (text.contains('MRT') ||
        text.contains('KAJANG') ||
        text.contains('PUTRAJAYA') ||
        text.contains('KGL') ||
        text.contains('PYL')) {
      return 'MRT';
    }
    if (text.contains('LRT') ||
        text.contains('KELANA') ||
        text.contains('AMPANG') ||
        text.contains('SRI PETALING') ||
        text.contains('KJL') ||
        text.contains('AGL') ||
        text.contains('SPL')) {
      return 'LRT';
    }
    return routeType == 1 ? 'Metro' : 'Rail';
  }
}

/// A single row from GTFS `stop_times.txt` — one scheduled visit of a
/// trip to a stop. `arrivalTime`/`departureTime` are GTFS time strings
/// ("HH:MM:SS") which can exceed "24:00:00" for trips that run past
/// midnight — see [GtfsStopTime] usage in TransitRepository.
class GtfsStopTime {
  final String tripId;
  final String stopId;
  final String arrivalTime;
  final String departureTime;
  final int stopSequence;

  const GtfsStopTime({
    required this.tripId,
    required this.stopId,
    required this.arrivalTime,
    required this.departureTime,
    required this.stopSequence,
  });
}

/// A single row from GTFS `trips.txt` — one scheduled run of a route.
class GtfsTrip {
  final String tripId;
  final String routeId;
  final String serviceId;
  final String shapeId;
  final int? directionId;

  const GtfsTrip({
    required this.tripId,
    required this.routeId,
    required this.serviceId,
    this.shapeId = '',
    this.directionId,
  });
}

/// One ordered geographic point from GTFS `shapes.txt`.
class GtfsShapePoint {
  final String shapeId;
  final double lat;
  final double lon;
  final int sequence;

  const GtfsShapePoint({
    required this.shapeId,
    required this.lat,
    required this.lon,
    required this.sequence,
  });
}

/// A repeating service window from GTFS `frequencies.txt`.
class GtfsFrequency {
  final String tripId;
  final String startTime;
  final String endTime;
  final int headwaySeconds;

  const GtfsFrequency({
    required this.tripId,
    required this.startTime,
    required this.endTime,
    required this.headwaySeconds,
  });
}

/// A single row from GTFS `calendar.txt` — which days of the week a
/// `service_id` runs, and the date range it's valid for. Used to filter
/// `trips.txt` down to only the trips actually running *today*, so "next
/// departure" and "last service" reflect today's real schedule instead of
/// every trip ever defined for the route.
///
class GtfsCalendarService {
  final String serviceId;
  final bool monday;
  final bool tuesday;
  final bool wednesday;
  final bool thursday;
  final bool friday;
  final bool saturday;
  final bool sunday;
  final String startDate;
  final String endDate;

  const GtfsCalendarService({
    required this.serviceId,
    required this.monday,
    required this.tuesday,
    required this.wednesday,
    required this.thursday,
    required this.friday,
    required this.saturday,
    required this.sunday,
    required this.startDate,
    required this.endDate,
  });
}

/// A service-day override from GTFS `calendar_dates.txt`.
/// `exceptionType` is 1 when service is added and 2 when it is removed.
class GtfsCalendarDate {
  final String serviceId;
  final String date;
  final int exceptionType;

  const GtfsCalendarDate({
    required this.serviceId,
    required this.date,
    required this.exceptionType,
  });
}
