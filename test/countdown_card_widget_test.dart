import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebound/modules/last_service_tracker/widgets/countdown_card.dart';
import 'package:homebound/shared/models/stop.dart';
import 'package:homebound/shared/theme/app_theme.dart';
import 'package:latlong2/latlong.dart';

void main() {
  testWidgets('long bus details stay inside the countdown card',
      (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const stop = Stop(
      name: 'PJ532 ONE UTAMA LDP WITH AN EXTRA LONG STOP NAME',
      platform:
          'Bus stop · PJ05 — Bandar Utama to Stesen LRT Taman Bahagia · PJ06 — Bandar Utama to Damansara Damai',
      position: LatLng(3.1494, 101.6167),
      timeToDeparture: Duration(minutes: 30, seconds: 31),
      urgency: ServiceUrgency.onTime,
      transportMode: 'Bus',
      routeLabel:
          'PJ05 — Bandar Utama to Stesen LRT Taman Bahagia · PJ06 — Bandar Utama to Damansara Damai',
      lastService: '11:45 PM',
    );

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: const Scaffold(
        body: Padding(
          padding: EdgeInsets.all(20),
          child: CountdownCard(
            stop: stop,
            remaining: Duration(minutes: 30, seconds: 31),
            urgency: ServiceUrgency.onTime,
          ),
        ),
      ),
    ));

    expect(find.text('PJ532 ONE UTAMA LDP WITH AN EXTRA LONG STOP NAME'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bus card distinguishes scheduled and live estimates',
      (tester) async {
    const scheduled = Stop(
      name: 'Test stop',
      platform: 'Bus stop · T250',
      position: LatLng(3.1494, 101.6167),
      timeToDeparture: Duration(minutes: 12),
      urgency: ServiceUrgency.closingSoon,
      transportMode: 'Bus',
      routeLabel: 'T250',
    );

    Widget card(Stop stop) => MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: CountdownCard(
              stop: stop,
              remaining: stop.timeToDeparture,
              urgency: stop.urgency,
            ),
          ),
        );

    await tester.pumpWidget(card(scheduled));
    expect(find.text('Official scheduled departure · live bus unavailable'),
        findsOneWidget);

    await tester.pumpWidget(card(scheduled.copyWith(isLiveEstimate: true)));
    expect(find.text('Estimated from the latest live bus position'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
