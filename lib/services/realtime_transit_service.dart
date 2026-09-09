import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../shared/models/transit_vehicle.dart';

/// Reads RapidKL's official GTFS-Realtime vehicle-position feed. The feed is
/// protobuf rather than JSON; this deliberately decodes only the fields used
/// here (vehicle id, route id, latitude, longitude, and timestamp).
///
/// Field numbers below follow the standard gtfs-realtime.proto:
///   FeedEntity: id=1, is_deleted=2, trip_update=3, vehicle=4, alert=5
///   VehiclePosition: trip=1, position=2, current_stop_sequence=3,
///                    stop_id=4, current_status=5, timestamp=6,
///                    congestion_level=7, vehicle(descriptor)=8
class RealtimeTransitService {
  RealtimeTransitService._();
  static final instance = RealtimeTransitService._();

  static const _baseUrl =
      'https://api.data.gov.my/gtfs-realtime/vehicle-position/prasarana';

  /// Official live positions are currently available for Rapid Bus, not rail.
  Future<List<TransitVehicle>> fetchVehicles(
      {String category = 'rapid-bus-kl'}) async {
    final uri = Uri.parse('$_baseUrl?category=$category');
    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw http.ClientException(
          'Realtime API returned ${response.statusCode}');
    }
    return parseVehicles(response.bodyBytes, category: category);
  }

  /// Parses a complete FeedMessage. FeedEntity is field 2 at the feed level;
  /// VehiclePosition is field 4 inside each entity.
  List<TransitVehicle> parseVehicles(Uint8List feed,
      {String category = 'rapid-bus-kl'}) {
    final vehicles = <TransitVehicle>[];
    for (final entityField
        in _fields(feed).where((field) => field.number == 2)) {
      final entity = entityField.bytes;
      if (entity == null) continue;
      for (final vehicleField
          in _fields(entity).where((field) => field.number == 4)) {
        final payload = vehicleField.bytes;
        if (payload == null) continue;
        final vehicle = _parseVehicle(payload, category);
        if (vehicle != null) vehicles.add(vehicle);
      }
    }
    return vehicles;
  }

  TransitVehicle? _parseVehicle(Uint8List vehicleMessage, String category) {
    String route = '';
    String tripId = '';
    String vehicleId = '';
    double? latitude;
    double? longitude;
    int timestamp = 0;
    int? currentStopSequence;
    String? stopId;
    double? speedMps;
    for (final field in _fields(vehicleMessage)) {
      if (field.number == 1 && field.bytes != null) {
        // TripDescriptor: route_id is field 5.
        for (final trip in _fields(field.bytes!)) {
          if (trip.number == 1 && trip.bytes != null) {
            tripId = String.fromCharCodes(trip.bytes!);
          }
          if (trip.number == 5 && trip.bytes != null) {
            route = String.fromCharCodes(trip.bytes!);
          }
        }
      } else if (field.number == 2 && field.bytes != null) {
        // Position: latitude=1 (fixed32), longitude=2 (fixed32).
        for (final point in _fields(field.bytes!)) {
          if (point.number == 1 && point.fixed32 != null) {
            latitude = _float(point.fixed32!);
          }
          if (point.number == 2 && point.fixed32 != null) {
            longitude = _float(point.fixed32!);
          }
          if (point.number == 5 && point.fixed32 != null) {
            speedMps = _float(point.fixed32!);
          }
        }
      } else if (field.number == 3 && field.value != null) {
        currentStopSequence = field.value;
      } else if (field.number == 4 && field.bytes != null) {
        stopId = String.fromCharCodes(field.bytes!);
      } else if (field.number == 8 && field.bytes != null) {
        // VehicleDescriptor is field 8 (not 3 — field 3 is
        // current_stop_sequence, a varint).
        for (final descriptor in _fields(field.bytes!)) {
          if (descriptor.number == 1 && descriptor.bytes != null) {
            vehicleId = String.fromCharCodes(descriptor.bytes!);
          }
        }
      } else if (field.number == 6 && field.value != null) {
        timestamp = field.value!;
      }
    }
    if (latitude == null || longitude == null) return null;
    final isRail = category.contains('rail');
    return TransitVehicle(
      id: vehicleId.isEmpty ? 'Vehicle' : vehicleId,
      routeLabel: route.isEmpty
          ? (isRail ? 'Rapid Rail service' : 'Rapid KL bus')
          : (isRail ? 'Rapid Rail $route' : 'Rapid KL $route'),
      routeId: route,
      tripId: tripId,
      currentStopSequence: currentStopSequence,
      stopId: stopId,
      speedMps: speedMps,
      feedCategory: category,
      position: LatLng(latitude, longitude),
      updatedAt: timestamp > 0
          ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000)
          : DateTime.now(),
    );
  }

  double _float(int bits) {
    final data = ByteData(4)..setUint32(0, bits, Endian.little);
    return data.getFloat32(0, Endian.little);
  }

  List<_ProtoField> _fields(Uint8List data) {
    final fields = <_ProtoField>[];
    var index = 0;
    while (index < data.length) {
      final tag = _readVarint(data, index);
      index = tag.next;
      final number = tag.value >> 3;
      switch (tag.value & 7) {
        case 0:
          final value = _readVarint(data, index);
          fields.add(_ProtoField(number, value: value.value));
          index = value.next;
          break;
        case 2:
          final length = _readVarint(data, index);
          index = length.next;
          final end = index + length.value;
          if (end > data.length) return fields;
          fields.add(_ProtoField(number,
              bytes: Uint8List.sublistView(data, index, end)));
          index = end;
          break;
        case 5:
          if (index + 4 > data.length) return fields;
          fields.add(_ProtoField(number,
              fixed32: ByteData.sublistView(data, index, index + 4)
                  .getUint32(0, Endian.little)));
          index += 4;
          break;
        default:
          return fields;
      }
    }
    return fields;
  }

  _Varint _readVarint(Uint8List data, int index) {
    var value = 0;
    var shift = 0;
    while (index < data.length) {
      final byte = data[index++];
      value |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) break;
      shift += 7;
    }
    return _Varint(value, index);
  }
}

class _ProtoField {
  final int number;
  final int? value;
  final int? fixed32;
  final Uint8List? bytes;
  const _ProtoField(this.number, {this.value, this.fixed32, this.bytes});
}

class _Varint {
  final int value;
  final int next;
  const _Varint(this.value, this.next);
}
