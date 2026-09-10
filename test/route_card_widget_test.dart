import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebound/modules/route_planner/widgets/route_card.dart';
import 'package:homebound/shared/models/route_model.dart';
import 'package:homebound/shared/theme/app_theme.dart';

void main() {
  const route = RouteOption(
    departureTime: '8:00 AM',
    arrivalTime: '8:30 AM',
    mode: 'MRT → LRT',
    etaSummary: 'Arrives 8:30 AM · 30 min total',
    status: ServiceUrgency.onTime,
    totalMinutes: 30,
    transferCount: 1,
    departureServiceSeconds: 8 * 3600,
    arrivalServiceSeconds: 8 * 3600 + 30 * 60,
    steps: [
      'Take Kajang Line from Station A',
      'Change service at Station B',
      'Get off at Station C',
    ],
  );

  testWidgets('route card opens detailed timeline and progress tracker',
      (tester) async {
    var started = false;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: Builder(builder: (context) {
          return RouteCard(
            route: route,
            optionIndex: 0,
            onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => RouteDetailsSheet(
                route: route,
                onGo: () => started = true,
              ),
            ),
          );
        }),
      ),
    ));

    expect(find.text('FASTEST'), findsOneWidget);
    await tester.tap(find.byType(RouteCard));
    await tester.pumpAndSettle();
    expect(find.text('Journey details'), findsOneWidget);
    expect(find.text('How to get there'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Go · start journey'), findsOneWidget);
    await tester.tap(find.text('Go · start journey'));
    await tester.pumpAndSettle();
    expect(started, isTrue);
    expect(tester.takeException(), isNull);
  });
}
