import 'package:latlong2/latlong.dart';

class SavedPlace {
  final String slot;
  final String name;
  final LatLng position;

  const SavedPlace({
    required this.slot,
    required this.name,
    required this.position,
  });

  Map<String, Object> toJson() => {
        'slot': slot,
        'name': name,
        'latitude': position.latitude,
        'longitude': position.longitude,
      };

  static SavedPlace? fromJson(Map<String, dynamic> json) {
    final slot = json['slot'] as String?;
    final name = json['name'] as String?;
    final latitude = (json['latitude'] as num?)?.toDouble();
    final longitude = (json['longitude'] as num?)?.toDouble();
    if (slot == null || name == null || latitude == null || longitude == null) {
      return null;
    }
    return SavedPlace(
      slot: slot,
      name: name,
      position: LatLng(latitude, longitude),
    );
  }
}
