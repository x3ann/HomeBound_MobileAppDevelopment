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

  const GtfsRoute({
    required this.routeId,
    required this.shortName,
    required this.longName,
  });
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

  const GtfsTrip({
    required this.tripId,
    required this.routeId,
    required this.serviceId,
  });
}

/// A single row from GTFS `calendar.txt` — which days of the week a
/// `service_id` runs, and the date range it's valid for. Used to filter
/// `trips.txt` down to only the trips actually running *today*, so "next
/// departure" and "last service" reflect today's real schedule instead of
/// every trip ever defined for the route.
///
/// Note: this does not read `calendar_dates.txt` exceptions (holiday
/// add/remove days), so schedules on exception dates may be slightly off.
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