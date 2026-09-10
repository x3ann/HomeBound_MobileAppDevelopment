import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../shared/models/saved_place.dart';

class SavedPlaceService {
  static const _storageKey = 'saved_planner_origins_v1';

  Future<List<SavedPlace>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getStringList(_storageKey) ?? const [];
    return encoded
        .map((value) {
          try {
            return SavedPlace.fromJson(
              jsonDecode(value) as Map<String, dynamic>,
            );
          } catch (_) {
            return null;
          }
        })
        .whereType<SavedPlace>()
        .toList();
  }

  Future<void> save(SavedPlace place) async {
    final preferences = await SharedPreferences.getInstance();
    final places = await load();
    final updated = [
      ...places.where((item) => item.slot != place.slot),
      place,
    ];
    await preferences.setStringList(
      _storageKey,
      updated.map((item) => jsonEncode(item.toJson())).toList(),
    );
  }

  Future<void> remove(String slot) async {
    final preferences = await SharedPreferences.getInstance();
    final places = await load();
    await preferences.setStringList(
      _storageKey,
      places
          .where((item) => item.slot != slot)
          .map((item) => jsonEncode(item.toJson()))
          .toList(),
    );
  }
}
