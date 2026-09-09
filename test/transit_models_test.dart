import 'package:flutter_test/flutter_test.dart';
import 'package:homebound/services/transit_repository.dart';
import 'package:homebound/services/gtfs_service.dart';
import 'package:homebound/shared/models/stop.dart';
import 'package:homebound/shared/theme/app_theme.dart';
import 'package:latlong2/latlong.dart';

void main() {
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
}
