import 'package:shared_preferences/shared_preferences.dart';

class EmergencyContactService {
  EmergencyContactService({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const _contactKey = 'emergency_contact_number';
  final SharedPreferencesAsync _preferences;

  Future<String?> load() => _preferences.getString(_contactKey);

  Future<void> save(String value) async {
    final normalized = normalize(value);
    if (!isValid(normalized)) {
      throw const FormatException('Invalid emergency contact number');
    }
    await _preferences.setString(_contactKey, normalized);
  }

  static String normalize(String value) {
    final trimmed = value.trim();
    final hasPlus = trimmed.startsWith('+');
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    return hasPlus ? '+$digits' : digits;
  }

  static bool isValid(String value) {
    final normalized = normalize(value);
    return RegExp(r'^\+?\d{7,15}$').hasMatch(normalized);
  }

  static String buildMessage({
    required double latitude,
    required double longitude,
    required DateTime capturedAt,
    double? accuracyMeters,
  }) {
    final accuracy = accuracyMeters == null
        ? ''
        : '\nAccuracy: about ${accuracyMeters.round()} metres.';
    return 'SOS! I may need help. My location was captured at '
        '${capturedAt.toLocal().toIso8601String()}.\n'
        'Location: https://maps.google.com/?q='
        '${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}'
        '$accuracy';
  }

  static Uri smsUri({required String contact, required String message}) => Uri(
        scheme: 'sms',
        path: normalize(contact),
        query: 'body=${Uri.encodeComponent(message)}',
      );
}
