import 'package:flutter/material.dart';

import '../shared/widgets/bottom_nav.dart';

import '../modules/last_service_tracker/last_service_tracker_screen.dart';
import '../modules/live_map/live_map_screen.dart';
import '../modules/route_planner/route_planner_screen.dart';
import '../modules/ai_delay_prediction/ai_delay_prediction_screen.dart';
import '../modules/sos_panic/sos_panic_screen.dart';

class DashboardShell extends StatefulWidget {
  const DashboardShell({super.key});

  @override
  State<DashboardShell> createState() => _DashboardShellState();
}

class _DashboardShellState extends State<DashboardShell> {
  int _index = 0;

  void _goToTab(int i) {
    setState(() {
      _index = i;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    final screens = [
      LastServiceTrackerScreen(
        onOpenLiveMap: () => _goToTab(1),
      ),
      const LiveMapScreen(),
      const RoutePlannerScreen(),
      const AiDelayPredictionScreen(),
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