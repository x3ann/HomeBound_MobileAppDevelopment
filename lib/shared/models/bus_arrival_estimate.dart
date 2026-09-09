import 'stop.dart';

/// Estimated bus arrival derived from a live vehicle position and its
/// official static trip stop sequence. It is not an operator trip update.
class BusArrivalEstimate {
  final Stop stop;
  final String routeLabel;
  final String vehicleId;
  final Duration eta;

  const BusArrivalEstimate({
    required this.stop,
    required this.routeLabel,
    required this.vehicleId,
    required this.eta,
  });

  String get etaLabel => eta.inMinutes < 1 ? 'Due' : '${eta.inMinutes} min';
}
