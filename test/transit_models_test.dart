import 'package:flutter_test/flutter_test.dart';
import 'package:homebound/services/transit_repository.dart';
import 'package:homebound/services/gtfs_service.dart';
import 'package:homebound/services/gtfs_models.dart';
import 'package:homebound/shared/models/stop.dart';
import 'package:homebound/shared/models/planned_journey.dart';
import 'package:homebound/shared/models/route_model.dart';
import 'package:homebound/shared/theme/app_theme.dart';
import 'package:latlong2/latlong.dart';

void main() {
  test('long journey durations use hours and minutes', () {
    expect(RouteOption.formatMinutes(52), '52 min');
    expect(RouteOption.formatMinutes(60), '1h');
    expect(RouteOption.formatMinutes(404), '6h 44m');
  });

  test('departure proximity labels describe the next arrival', () {
    expect(ServiceUrgency.onTime.label, 'SCHEDULED');
    expect(ServiceUrgency.closingSoon.label, 'ARRIVING SOON');
    expect(ServiceUrgency.critical.label, 'DUE SOON');
  });

  test('planned journey reports scheduled progress and active instruction', () {
    const endpoint = Stop(
      name: 'Station',
      platform: 'Rail station',
      position: LatLng(3.1390, 101.6869),
      timeToDeparture: Duration.zero,
      urgency: ServiceUrgency.onTime,
    );
    const journey = PlannedJourney(
      origin: endpoint,
      destination: endpoint,
      route: RouteOption(
        departureTime: '8:00 AM',
        arrivalTime: '8:30 AM',
        mode: 'MRT',
        etaSummary: '30 min',
        status: ServiceUrgency.onTime,
        totalMinutes: 30,
        departureServiceSeconds: 8 * 3600,
        arrivalServiceSeconds: 8 * 3600 + 30 * 60,
        steps: ['Board', 'Ride', 'Exit'],
        checkpoints: [
          RouteCheckpoint(
            name: 'Interchange',
            position: LatLng(3.15, 101.69),
            instruction: 'Change line',
            serviceSeconds: 8 * 3600 + 10 * 60,
          ),
        ],
      ),
    );

    expect(journey.progressAt(8 * 3600), 0);
    expect(journey.progressAt(8 * 3600 + 15 * 60), closeTo(.5, .001));
    expect(journey.activeStepAt(8 * 3600 + 15 * 60), 1);
    expect(journey.progressAt(9 * 3600), 1);
    expect(journey.route.checkpoints.single.name, 'Interchange');
    expect(journey.activeCheckpointAt(8 * 3600 + 15 * 60), 0);
  });

  test('planned journey progress includes walking and waiting time', () {
    const route = RouteOption(
      departureTime: '8:10 AM',
      arrivalTime: '8:30 AM',
      mode: 'Bus',
      etaSummary: '30 min total',
      status: ServiceUrgency.onTime,
      totalMinutes: 30,
      departureServiceSeconds: 8 * 3600 + 10 * 60,
      arrivalServiceSeconds: 8 * 3600 + 30 * 60,
    );

    expect(route.journeyStartServiceSeconds, 8 * 3600);
    expect(route.progressAt(8 * 3600 + 5 * 60), closeTo(1 / 6, .001));
  });

  test('planned journey follows a phone position near its checkpoints', () {
    const origin = Stop(
      name: 'Origin',
      platform: 'Rail station',
      position: LatLng(3.0, 101.0),
      timeToDeparture: Duration.zero,
      urgency: ServiceUrgency.onTime,
    );
    const destination = Stop(
      name: 'Destination',
      platform: 'Rail station',
      position: LatLng(3.0, 101.02),
      timeToDeparture: Duration.zero,
      urgency: ServiceUrgency.onTime,
    );
    const journey = PlannedJourney(
      origin: origin,
      destination: destination,
      route: RouteOption(
        departureTime: '8:00 AM',
        arrivalTime: '8:30 AM',
        mode: 'MRT',
        etaSummary: '30 min',
        status: ServiceUrgency.onTime,
        steps: ['Start', 'Change', 'Arrive'],
        checkpoints: [
          RouteCheckpoint(
            name: 'Middle',
            position: LatLng(3.0, 101.01),
            instruction: 'Change line',
          ),
        ],
      ),
    );

    expect(
        journey.progressForPosition(const LatLng(3.0, 101.0)), closeTo(0, .01));
    expect(journey.progressForPosition(const LatLng(3.0, 101.01)),
        closeTo(.5, .02));
    expect(journey.progressForPosition(const LatLng(3.0, 101.02)),
        closeTo(1, .01));
    expect(
      journey.progressForPosition(const LatLng(3.02, 101.01)),
      isNull,
    );
  });

  test('GTFS CSV parser keeps rows after quoted CRLF fields', () {
    final rows = GtfsService.parseCsvContent(
      'id,name\r\n1,Before\r\n2,"MITSUI OUTLET , KLIA 2"\r\n3,After\r\n',
    );

    expect(rows, hasLength(4));
    expect(rows[2][1], 'MITSUI OUTLET , KLIA 2');
    expect(rows[3], ['3', 'After']);
  });

  test('orders official stops by distance and records distance', () {
    const origin = LatLng(3.1390, 101.6869);
    const near = Stop(
      name: 'Near',
      platform: 'Rail station',
      position: LatLng(3.1400, 101.6870),
      timeToDeparture: Duration(minutes: 5),
      urgency: ServiceUrgency.critical,
    );
    const far = Stop(
      name: 'Far',
      platform: 'Rail station',
      position: LatLng(3.2000, 101.7000),
      timeToDeparture: Duration(minutes: 10),
      urgency: ServiceUrgency.onTime,
    );

    final sorted = TransitRepository.instance.sortByDistance(
      const [far, near],
      origin,
    );

    expect(sorted.map((stop) => stop.name), ['Near', 'Far']);
    expect(sorted.first.distanceMeters, isNotNull);
    expect(sorted.first.distanceMeters!, lessThan(sorted.last.distanceMeters!));
  });

  test('expired departures are not shown as a zero-minute countdown', () {
    const stop = Stop(
      name: 'Station',
      platform: 'Rail station',
      position: LatLng(3.1390, 101.6869),
      timeToDeparture: Duration.zero,
      urgency: ServiceUrgency.critical,
    );

    expect(stop.formattedCountdown, 'No more today');
  });

  test('after-midnight service remains on the previous GTFS day', () {
    final afterMidnight = DateTime(2026, 9, 10, 1, 30);

    expect(
      GtfsService.serviceDateFor(afterMidnight),
      DateTime(2026, 9, 9),
    );
    expect(GtfsService.secondsIntoServiceDay(afterMidnight), 25 * 3600 + 1800);
  });

  test('morning service uses the current GTFS day', () {
    final morning = DateTime(2026, 9, 10, 6, 15);

    expect(GtfsService.serviceDateFor(morning), DateTime(2026, 9, 10));
    expect(GtfsService.secondsIntoServiceDay(morning), 6 * 3600 + 900);
  });

  test('calendar rules select only trips operating on the service date', () {
    const trips = [
      GtfsTrip(tripId: 'weekday-trip', routeId: '1', serviceId: 'weekday'),
      GtfsTrip(tripId: 'weekend-trip', routeId: '1', serviceId: 'weekend'),
    ];
    const calendar = [
      GtfsCalendarService(
        serviceId: 'weekday',
        monday: true,
        tuesday: true,
        wednesday: true,
        thursday: true,
        friday: true,
        saturday: false,
        sunday: false,
        startDate: '20260101',
        endDate: '20261231',
      ),
      GtfsCalendarService(
        serviceId: 'weekend',
        monday: false,
        tuesday: false,
        wednesday: false,
        thursday: false,
        friday: false,
        saturday: true,
        sunday: true,
        startDate: '20260101',
        endDate: '20261231',
      ),
    ];

    final active = GtfsService.activeTripIds(
      trips: trips,
      calendar: calendar,
      calendarDates: const [],
      serviceDate: DateTime(2026, 9, 10),
    );

    expect(active, {'weekday-trip'});
  });

  test('stop is out of service before the first departure', () {
    const stop = Stop(
      name: 'Station',
      platform: 'Rail station',
      position: LatLng(3.1390, 101.6869),
      timeToDeparture: Duration.zero,
      urgency: ServiceUrgency.onTime,
    );
    final result = TransitRepository.applyScheduleWindow(
      stop: stop,
      departureSeconds: const [6 * 3600, 23 * 3600],
      nowSeconds: 4 * 3600 + 37 * 60,
      modeLabel: 'LRT',
    );

    expect(result.isOperating, isFalse);
    expect(result.formattedCountdown, 'Out of service');
    expect(result.serviceStatusLabel, 'OUT OF SERVICE');

    final afterLast = TransitRepository.applyScheduleWindow(
      stop: stop,
      departureSeconds: const [6 * 3600, 23 * 3600],
      nowSeconds: 23 * 3600 + 30 * 60,
      modeLabel: 'LRT',
    );
    expect(afterLast.isOperating, isFalse);
    expect(afterLast.formattedCountdown, 'Out of service');
  });

  test('stop counts down only inside its operating window', () {
    const stop = Stop(
      name: 'Station',
      platform: 'Rail station',
      position: LatLng(3.1390, 101.6869),
      timeToDeparture: Duration.zero,
      urgency: ServiceUrgency.onTime,
    );
    final result = TransitRepository.applyScheduleWindow(
      stop: stop,
      departureSeconds: const [6 * 3600, 7 * 3600 + 5 * 60, 23 * 3600],
      nowSeconds: 7 * 3600,
      modeLabel: 'MRT',
      routeLabel: 'KGL',
    );

    expect(result.isOperating, isTrue);
    expect(result.timeToDeparture, const Duration(minutes: 5));
    expect(result.transportMode, 'MRT');
    expect(result.routeLabel, 'KGL');
  });

  test('GTFS routes expose readable transport modes', () {
    const mrt = GtfsRoute(
      routeId: '1',
      shortName: 'KGL',
      longName: 'Kajang Line',
      routeType: 1,
    );
    const monorail = GtfsRoute(
      routeId: '2',
      shortName: 'MRL',
      longName: 'KL Monorail',
      routeType: 12,
    );
    const bus = GtfsRoute(
      routeId: '3',
      shortName: 'T780',
      longName: 'Rapid KL Bus',
      routeType: 3,
    );

    expect(mrt.modeLabel, 'MRT');
    expect(monorail.modeLabel, 'Monorail');
    expect(bus.modeLabel, 'Bus');
    expect(mrt.displayName, 'KGL — Kajang Line');
  });

  test('station search text ignores common rail prefixes', () {
    expect(
      TransitRepository.normalizeSearchText('MRT Kepong Baru Station'),
      'kepong baru',
    );
  });

  test('route alternatives recommend the best arrival with transfer penalty',
      () {
    const slower = RouteOption(
      departureTime: '8:00 AM',
      mode: 'LRT',
      etaSummary: 'Arrives 8:35 AM',
      status: ServiceUrgency.onTime,
      arrivalServiceSeconds: 8 * 3600 + 35 * 60,
      totalMinutes: 35,
    );
    const fasterWithTransfer = RouteOption(
      departureTime: '8:02 AM',
      mode: 'MRT → LRT',
      etaSummary: 'Arrives 8:25 AM',
      status: ServiceUrgency.onTime,
      arrivalServiceSeconds: 8 * 3600 + 25 * 60,
      totalMinutes: 23,
      transferCount: 1,
    );

    final ranked = TransitRepository.rankRoutes(
      const [slower, fasterWithTransfer],
    );
    expect(ranked.first.mode, 'MRT → LRT');
    expect(ranked.first.isRecommended, isTrue);
    expect(ranked.last.isRecommended, isFalse);
  });
}
