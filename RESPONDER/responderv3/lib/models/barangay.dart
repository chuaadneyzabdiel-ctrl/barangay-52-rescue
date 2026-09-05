import 'package:latlong2/latlong.dart';

const String kDefaultBarangayId = '52';

const String kDemoLgu52Username = 'brgy52';
const String kDemoLgu52Password = 'Brgy52Admin1';

String normalizeBarangayId(String? value) {
  final v = value?.trim() ?? '';
  return v.isEmpty ? kDefaultBarangayId : v;
}

class BarangayRecord {
  final String id;
  final String name;
  final bool isActive;
  final List<String> neighbors;
  final LatLng mapCenter;

  const BarangayRecord({
    required this.id,
    required this.name,
    required this.isActive,
    required this.neighbors,
    required this.mapCenter,
  });

  String get label => name.trim().isEmpty ? 'Barangay $id' : name;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isActive': isActive,
        'neighbors': neighbors,
        'mapCenter': {
          'lat': mapCenter.latitude,
          'lng': mapCenter.longitude,
        },
      };

  factory BarangayRecord.fromJson(String key, Map<dynamic, dynamic> json) {
    final id = normalizeBarangayId((json['id'] ?? key)?.toString());
    final name = (json['name']?.toString() ?? 'Barangay $id').trim();
    final neighbors = <String>[];
    final rawNeighbors = json['neighbors'];
    if (rawNeighbors is List) {
      for (final e in rawNeighbors) {
        final n = e?.toString().trim() ?? '';
        if (n.isNotEmpty && !neighbors.contains(n)) neighbors.add(n);
      }
    }
    final center = json['mapCenter'];
    double lat = 14.6470319;
    double lng = 120.9768745;
    if (center is Map) {
      final cLat = center['lat'];
      final cLng = center['lng'];
      if (cLat is num) lat = cLat.toDouble();
      if (cLng is num) lng = cLng.toDouble();
    }
    return BarangayRecord(
      id: id,
      name: name.isEmpty ? 'Barangay $id' : name,
      isActive: json['isActive'] == true,
      neighbors: neighbors,
      mapCenter: LatLng(lat, lng),
    );
  }
}

/// Built-in catalog used before RTDB is seeded / reachable.
/// 52 is active; 53–55 stay coming-soon until an admin activates them.
const List<BarangayRecord> kBuiltInBarangays = [
  BarangayRecord(
    id: '52',
    name: 'Barangay 52',
    isActive: true,
    neighbors: ['53', '54', '55'],
    mapCenter: LatLng(14.6470319, 120.9768745),
  ),
  BarangayRecord(
    id: '53',
    name: 'Barangay 53',
    isActive: false,
    neighbors: ['52', '54'],
    mapCenter: LatLng(14.6482, 120.9781),
  ),
  BarangayRecord(
    id: '54',
    name: 'Barangay 54',
    isActive: false,
    neighbors: ['52', '53', '55'],
    mapCenter: LatLng(14.6459, 120.9756),
  ),
  BarangayRecord(
    id: '55',
    name: 'Barangay 55',
    isActive: false,
    neighbors: ['52', '54'],
    mapCenter: LatLng(14.6491, 120.9762),
  ),
];
