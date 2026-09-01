import 'package:uuid/uuid.dart';

class DomainStamp implements Comparable<DomainStamp> {
  final DateTime modifiedAt;
  final String deviceId;

  const DomainStamp({required this.modifiedAt, required this.deviceId});

  factory DomainStamp.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('stamp must be an object');
    final timestamp = value['modifiedAt'];
    final device = value['deviceId'];
    if (timestamp is! String || device is! String || device.isEmpty) {
      throw const FormatException('stamp fields are invalid');
    }
    final parsed = DateTime.tryParse(timestamp)?.toUtc();
    if (parsed == null) throw const FormatException('stamp time is invalid');
    return DomainStamp(modifiedAt: parsed, deviceId: device);
  }

  Map<String, dynamic> toJson() => {
        'modifiedAt': modifiedAt.toUtc().toIso8601String(),
        'deviceId': deviceId,
      };

  @override
  int compareTo(DomainStamp other) {
    final time = modifiedAt.compareTo(other.modifiedAt);
    return time != 0 ? time : deviceId.compareTo(other.deviceId);
  }
}

Map<String, dynamic> stampedValue(Object? value, DomainStamp stamp) => {
      'value': value,
      'stamp': stamp.toJson(),
    };

Map<String, dynamic> winningStampedValue(Object? left, Object? right) {
  final a = _decodeStamped(left);
  final b = _decodeStamped(right);
  return DomainStamp.fromJson(a['stamp'])
              .compareTo(DomainStamp.fromJson(b['stamp'])) >=
          0
      ? a
      : b;
}

Map<String, dynamic> _decodeStamped(Object? value) {
  if (value is! Map || !value.containsKey('value')) {
    throw const FormatException('stamped value is invalid');
  }
  DomainStamp.fromJson(value['stamp']);
  return Map<String, dynamic>.from(value);
}

String deterministicMigrationUuid(String namespace) =>
    const Uuid().v5(Namespace.url.value, namespace);
