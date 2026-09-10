import 'package:flutter_test/flutter_test.dart';
import 'package:homebound/screens/dashboard_shell.dart';

void main() {
  test('map and planner request counters cannot produce matching keys', () {
    for (var request = 0; request < 5; request++) {
      expect(
        dashboardPageKey(DashboardPage.liveMap, request),
        isNot(dashboardPageKey(DashboardPage.routePlanner, request)),
      );
    }
  });
}
