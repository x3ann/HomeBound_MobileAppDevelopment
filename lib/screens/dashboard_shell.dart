import 'package:flutter/material.dart';

import '../shared/widgets/bottom_nav.dart';

import '../modules/last_service_tracker/last_service_tracker_screen.dart';
import '../modules/live_map/live_map_screen.dart';
import '../modules/route_planner/route_planner_screen.dart';
import '../modules/ai_delay_prediction/ai_delay_prediction_screen.dart';
import '../modules/sos_panic/sos_panic_screen.dart';
import '../shared/models/stop.dart';

enum DashboardPage { liveMap, routePlanner }

Key dashboardPageKey(DashboardPage page, int request) =>
    ValueKey('${page.name}-$request');

class DashboardShell extends StatefulWidget {
  const DashboardShell({super.key});

  @override
  State<DashboardShell> createState() => _DashboardShellState();
}

class _DashboardShellState extends State<DashboardShell> {
  int _index = 0;
  String? _mapQuery;
  int _mapRequest = 0;
  int _plannerRequest = 0;
  Stop? _plannerOrigin;
  Stop? _plannerDestination;

  void _goToTab(int i) {
    setState(() {
      _index = i;
    });
  }

  void _openBusRoute(String route) {
    setState(() {
      _mapQuery = route;
      _mapRequest++;
      _index = 1;
    });
  }

  void _openPlannedJourney(Stop origin, Stop destination) {
    setState(() {
      _plannerOrigin = origin;
      _plannerDestination = destination;
      _plannerRequest++;
      _index = 2;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    final screens = [
      LastServiceTrackerScreen(
        onOpenLiveMap: () => _goToTab(1),
        onOpenBusRoute: _openBusRoute,
      ),
      LiveMapScreen(
        // Map and planner are siblings in the IndexedStack. Their request
        // counters can have the same value, so namespace the keys to keep
        // Flutter from reusing the wrong element during a tab hand-off.
        key: dashboardPageKey(DashboardPage.liveMap, _mapRequest),
        initialQuery: _mapQuery,
      ),
      RoutePlannerScreen(
        key: dashboardPageKey(DashboardPage.routePlanner, _plannerRequest),
        initialOrigin: _plannerOrigin,
        initialDestination: _plannerDestination,
      ),
      AiDelayPredictionScreen(onGoNow: _openPlannedJourney),
      const SosPanicScreen(),
    ];

    final content = SafeArea(
      child: IndexedStack(
        index: _index,
        children: screens,
      ),
    );

    final navigation = HomeboundBottomNav(
      currentIndex: _index,
      onTap: _goToTab,
    );

    return Scaffold(
      body: isLandscape
          ? Row(
              children: [
                navigation,
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            )
          : content,
      bottomNavigationBar: isLandscape ? null : navigation,
    );
  }
}
