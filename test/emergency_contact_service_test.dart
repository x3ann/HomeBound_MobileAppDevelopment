import 'package:flutter_test/flutter_test.dart';
import 'package:homebound/services/emergency_contact_service.dart';

void main() {
  test('normalizes and validates Malaysian and international phone numbers',
      () {
    expect(EmergencyContactService.normalize('012-345 6789'), '0123456789');
    expect(
        EmergencyContactService.normalize('+60 12-345 6789'), '+60123456789');
    expect(EmergencyContactService.isValid('012-345 6789'), isTrue);
    expect(EmergencyContactService.isValid('12'), isFalse);
  });

  test('emergency message includes timestamp, accuracy, and map coordinates',
      () {
    final message = EmergencyContactService.buildMessage(
      latitude: 3.139,
      longitude: 101.6869,
      capturedAt: DateTime.utc(2026, 9, 9, 12),
      accuracyMeters: 8.4,
    );

    expect(message, contains('3.139000,101.686900'));
    expect(message, contains('2026-09-09'));
    expect(message, contains('about 8 metres'));
  });

  test('SMS URI safely encodes message content', () {
    final uri = EmergencyContactService.smsUri(
      contact: '+60 12-345 6789',
      message: 'Help me & use this location',
    );

    expect(uri.scheme, 'sms');
    expect(uri.path, '+60123456789');
    expect(uri.query, contains('%26'));
    expect(uri.queryParameters['body'], 'Help me & use this location');
  });
}
