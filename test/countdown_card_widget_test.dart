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
}
