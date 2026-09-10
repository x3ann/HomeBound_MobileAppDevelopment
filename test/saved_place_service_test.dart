import 'package:flutter_test/flutter_test.dart';
import 'package:homebound/services/saved_place_service.dart';
import 'package:homebound/shared/models/saved_place.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('saves and replaces Home, Work, and Other origin slots', () async {
    final service = SavedPlaceService();
    await service.save(const SavedPlace(
      slot: 'Home',
      name: 'First home',
      position: LatLng(3.1, 101.6),
    ));
    await service.save(const SavedPlace(
      slot: 'Home',
      name: 'Updated home',
      position: LatLng(3.2, 101.7),
    ));

    final places = await service.load();
    expect(places, hasLength(1));
    expect(places.single.name, 'Updated home');
    expect(places.single.position.latitude, 3.2);
  });

  test('removes a saved origin slot', () async {
    final service = SavedPlaceService();
    await service.save(const SavedPlace(
      slot: 'Work',
      name: 'Office',
      position: LatLng(3.15, 101.7),
    ));
    await service.remove('Work');

    expect(await service.load(), isEmpty);
  });
}
