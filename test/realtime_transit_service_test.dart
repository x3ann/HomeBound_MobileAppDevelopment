import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebound/services/realtime_transit_service.dart';

void main() {
  test('decodes VehiclePosition nested inside FeedEntity', () {
    final trip = [
      ..._lengthField(1, 'trip-7'.codeUnits),
      ..._lengthField(5, 'KJ01'.codeUnits),
    ];
    final position = [
      ..._fixed32Field(1, 3.1390),
      ..._fixed32Field(2, 101.6869),
    ];
    final descriptor = _lengthField(1, 'BUS-42'.codeUnits);
    final vehicle = [
      ..._lengthField(1, trip),
      ..._lengthField(2, position),
      ..._varintField(3, 12),
      ..._lengthField(4, 'STOP-12'.codeUnits),
      ..._varintField(6, 1700000000),
      ..._lengthField(8, descriptor),
    ];
    final entity = [
      ..._lengthField(1, 'entity-1'.codeUnits),
      ..._lengthField(4, vehicle),
    ];
    final feed = Uint8List.fromList(_lengthField(2, entity));

    final result = RealtimeTransitService.instance.parseVehicles(feed);

    expect(result, hasLength(1));
    expect(result.single.id, 'BUS-42');
    expect(result.single.routeLabel, 'Rapid KL KJ01');
    expect(result.single.tripId, 'trip-7');
    expect(result.single.currentStopSequence, 12);
    expect(result.single.stopId, 'STOP-12');
    expect(result.single.position.latitude, closeTo(3.1390, 0.0001));
    expect(result.single.position.longitude, closeTo(101.6869, 0.0001));
  });
}

List<int> _lengthField(int number, List<int> value) => [
      ..._varint((number << 3) | 2),
      ..._varint(value.length),
      ...value,
    ];

List<int> _varintField(int number, int value) => [
      ..._varint(number << 3),
      ..._varint(value),
    ];

List<int> _fixed32Field(int number, double value) {
  final bytes = ByteData(4)..setFloat32(0, value, Endian.little);
  return [(number << 3) | 5, ...bytes.buffer.asUint8List()];
}

List<int> _varint(int value) {
  final bytes = <int>[];
  do {
    var byte = value & 0x7f;
    value >>= 7;
    if (value != 0) byte |= 0x80;
    bytes.add(byte);
  } while (value != 0);
  return bytes;
}
