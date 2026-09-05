import 'package:latlong2/latlong.dart';

import 'barangay.dart';

enum UnitType { ambulance, fireTruck, policeUnit, rescue }

enum UnitStatus { idle, dispatched, enRoute, onScene, returning }

enum SOSPriority { critical, high, medium, low }

enum SOSStatus { pending, dispatched, inProgress, resolved, completed, cancelled }

/// Category of emergency for an SOS. Shown to citizens when sending and to rescuers before accept.
enum SOSType {
  medical,
  fire,
  accident,
  flood,
  violence,
  other,
}

/// Label and description for each [SOSType] for UI and rescuer display.
class SOSTypeInfo {
  final String label;
  final String description;

  const SOSTypeInfo({required this.label, required this.description});

  static SOSTypeInfo forType(SOSType type) {
    return switch (type) {
      SOSType.medical => const SOSTypeInfo(
          label: 'Medical',
          description: 'Person injured or ill, needs ambulance or medical aid.',
        ),
      SOSType.fire => const SOSTypeInfo(
          label: 'Fire',
          description: 'Fire or smoke; needs fire response.',
        ),
      SOSType.accident => const SOSTypeInfo(
          label: 'Traffic Accident',
          description: 'Road accident; injuries or vehicle trapped.',
        ),
      SOSType.flood => const SOSTypeInfo(
          label: 'Flood / Water',
          description: 'Flooding or water emergency; rescue or evacuation.',
        ),
      SOSType.violence => const SOSTypeInfo(
          label: 'Violence / Security',
          description: 'Threat, assault, or security incident.',
        ),
      SOSType.other => const SOSTypeInfo(
          label: 'Other Emergency',
          description: 'Other emergency; describe in message.',
        ),
    };
  }
}

enum HazardType { flood, fire, structuralCollapse, roadBlock, chemicalSpill, other }

class HazardZone {
  final String id;
  final String name;
  final HazardType type;
  final List<LatLng> polygon;
  final double severityWeight;
  final DateTime reportedAt;
  final DateTime? resolvedAt;

  const HazardZone({
    required this.id,
    required this.name,
    required this.type,
    required this.polygon,
    this.severityWeight = double.infinity,
    required this.reportedAt,
    this.resolvedAt,
  });

  bool get isActive => resolvedAt == null;

  bool containsPoint(LatLng point) {
    int crossings = 0;
    for (int i = 0; i < polygon.length; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % polygon.length];
      if ((a.latitude <= point.latitude && b.latitude > point.latitude) ||
          (b.latitude <= point.latitude && a.latitude > point.latitude)) {
        final t =
            (point.latitude - a.latitude) / (b.latitude - a.latitude);
        if (point.longitude < a.longitude + t * (b.longitude - a.longitude)) {
          crossings++;
        }
      }
    }
    return crossings.isOdd;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'polygon': polygon.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
        'severityWeight': severityWeight.isFinite ? severityWeight : 9999.0,
        'reportedAt': reportedAt.millisecondsSinceEpoch,
        'resolvedAt': resolvedAt?.millisecondsSinceEpoch,
      };

  factory HazardZone.fromJson(Map<String, dynamic> json) {
    return HazardZone(
      id: json['id'] as String,
      name: json['name'] as String,
      type: HazardType.values.firstWhere((t) => t.name == json['type']),
      polygon: (json['polygon'] as List)
          .map((p) => LatLng(
                (p['lat'] as num).toDouble(),
                (p['lng'] as num).toDouble(),
              ))
          .toList(),
      severityWeight: (json['severityWeight'] as num?)?.toDouble() ?? double.infinity,
      reportedAt: DateTime.fromMillisecondsSinceEpoch(json['reportedAt'] as int),
      resolvedAt: json['resolvedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['resolvedAt'] as int)
          : null,
    );
  }
}

class RescueUnit {
  final String id;
  final String callSign;
  final UnitType type;
  UnitStatus status;
  LatLng position;
  String? assignedSOSId;
  final String stationId;
  final String barangayId;

  RescueUnit({
    required this.id,
    required this.callSign,
    required this.type,
    this.status = UnitStatus.idle,
    required this.position,
    this.assignedSOSId,
    required this.stationId,
    this.barangayId = kDefaultBarangayId,
  });

  bool get isAvailable => status == UnitStatus.idle;

  Map<String, dynamic> toJson() => {
        'id': id,
        'callSign': callSign,
        'type': type.name,
        'status': status.name,
        'lat': position.latitude,
        'lng': position.longitude,
        'assignedSOSId': assignedSOSId,
        'stationId': stationId,
        'barangayId': normalizeBarangayId(barangayId),
      };

  factory RescueUnit.fromJson(Map<String, dynamic> json) {
    return RescueUnit(
      id: json['id'] as String,
      callSign: json['callSign'] as String,
      type: UnitType.values.firstWhere((t) => t.name == json['type']),
      status: UnitStatus.values.firstWhere((s) => s.name == json['status']),
      position: LatLng(
        (json['lat'] as num).toDouble(),
        (json['lng'] as num).toDouble(),
      ),
      assignedSOSId: json['assignedSOSId'] as String?,
      stationId: json['stationId'] as String,
      barangayId: normalizeBarangayId(json['barangayId']?.toString()),
    );
  }
}

class SOSRequest {
  final String id;
  LatLng location;
  final String citizenId;
  final String citizenName;
  final String? message;
  final SOSPriority priority;
  final SOSType sosType;
  SOSStatus status;
  final DateTime createdAt;
  String? assignedUnitId;
  /// When set, this SOS is in history (completed/resolved).
  final DateTime? completedAt;
  final String? preferredFacilityId;
  final String? preferredFacilityName;
  final LatLng? preferredFacilityLocation;
  /// True when the citizen dropped a pin (or reported for someone else).
  /// Live GPS of the reporter must not overwrite [location].
  final bool locationIsPinned;
  /// Optional name of the person in need when this SOS is a proxy report.
  final String? reportedForName;
  /// Optional callback number from the sender (guest or registered). Never required.
  final String? callbackPhone;
  /// Optional scene photo (https URL or data:image JPEG). Never required.
  final String? scenePhotoUrl;
  /// Home barangay that owns this SOS. Missing values are treated as "52".
  final String barangayId;
  /// Neighbor barangays that accepted mutual aid for this SOS.
  List<String> assistingBarangayIds;
  /// Unit types requested per assisting barangay (`ambulance`, `fireTruck`, ...).
  Map<String, List<String>> assistingUnitTypes;

  SOSRequest({
    required this.id,
    required this.location,
    required this.citizenId,
    required this.citizenName,
    this.message,
    this.priority = SOSPriority.high,
    this.sosType = SOSType.medical,
    this.status = SOSStatus.pending,
    required this.createdAt,
    this.assignedUnitId,
    this.completedAt,
    this.preferredFacilityId,
    this.preferredFacilityName,
    this.preferredFacilityLocation,
    this.locationIsPinned = false,
    this.reportedForName,
    this.callbackPhone,
    this.scenePhotoUrl,
    this.barangayId = kDefaultBarangayId,
    this.assistingBarangayIds = const [],
    this.assistingUnitTypes = const {},
  });

  bool get isProxyReport =>
      reportedForName != null && reportedForName!.trim().isNotEmpty;

  bool get hasCallbackPhone =>
      callbackPhone != null && callbackPhone!.trim().isNotEmpty;

  bool get hasScenePhoto =>
      scenePhotoUrl != null && scenePhotoUrl!.trim().isNotEmpty;

  bool isOwnedByBarangay(String id) =>
      normalizeBarangayId(barangayId) == normalizeBarangayId(id);

  bool isVisibleToBarangay(String id) {
    final target = normalizeBarangayId(id);
    if (isOwnedByBarangay(target)) return true;
    return assistingBarangayIds.any((b) => normalizeBarangayId(b) == target);
  }

  bool allowsAssistingUnitType(String barangayId, UnitType type) {
    final types = assistingUnitTypes[normalizeBarangayId(barangayId)] ?? const [];
    if (types.isEmpty) return true;
    return types.contains(type.name);
  }

  /// True if this request should appear on the active map.
  bool get isActive =>
      status != SOSStatus.resolved &&
      status != SOSStatus.completed &&
      status != SOSStatus.cancelled;

  /// Short description for this SOS type (for rescuers).
  String get typeDescription => SOSTypeInfo.forType(sosType).description;

  Map<String, dynamic> toJson() => {
        'id': id,
        'lat': location.latitude,
        'lng': location.longitude,
        'citizenId': citizenId,
        'citizenName': citizenName,
        'message': message,
        'priority': priority.name,
        'sosType': sosType.name,
        'status': status.name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'assignedUnitId': assignedUnitId,
        if (completedAt != null) 'completedAt': completedAt!.millisecondsSinceEpoch,
        if (preferredFacilityId != null) 'preferredFacilityId': preferredFacilityId,
        if (preferredFacilityName != null)
          'preferredFacilityName': preferredFacilityName,
        if (preferredFacilityLocation != null)
          'preferredFacilityLat': preferredFacilityLocation!.latitude,
        if (preferredFacilityLocation != null)
          'preferredFacilityLng': preferredFacilityLocation!.longitude,
        if (locationIsPinned) 'locationIsPinned': true,
        if (reportedForName != null && reportedForName!.trim().isNotEmpty)
          'reportedForName': reportedForName!.trim(),
        if (callbackPhone != null && callbackPhone!.trim().isNotEmpty)
          'callbackPhone': callbackPhone!.trim(),
        if (scenePhotoUrl != null && scenePhotoUrl!.trim().isNotEmpty)
          'scenePhotoUrl': scenePhotoUrl!.trim(),
        'barangayId': normalizeBarangayId(barangayId),
        if (assistingBarangayIds.isNotEmpty)
          'assistingBarangayIds': assistingBarangayIds,
        if (assistingUnitTypes.isNotEmpty)
          'assistingUnitTypes': assistingUnitTypes,
      };

  factory SOSRequest.fromJson(Map<String, dynamic> json) {
    final sosTypeStr = json['sosType'] as String?;
    final sosType = sosTypeStr != null
        ? SOSType.values.firstWhere(
            (t) => t.name == sosTypeStr,
            orElse: () => SOSType.other,
          )
        : SOSType.other;
    final statusStr = json['status'] as String?;
    final status = statusStr != null
        ? SOSStatus.values.firstWhere(
            (s) => s.name == statusStr,
            orElse: () => SOSStatus.pending,
          )
        : SOSStatus.pending;
    final completedAtVal = json['completedAt'];
    final completedAt = completedAtVal != null && completedAtVal is num
        ? DateTime.fromMillisecondsSinceEpoch(completedAtVal.toInt())
        : null;

    final rawId = json['id']?.toString() ?? '';
    final id = rawId.isEmpty ? 'unknown' : rawId;
    final lat = json['lat'] is num ? (json['lat'] as num).toDouble() : 0.0;
    final lng = json['lng'] is num ? (json['lng'] as num).toDouble() : 0.0;
    final citizenId = (json['citizenId']?.toString()) ?? '';
    final citizenName = (json['citizenName']?.toString()) ?? 'Unknown';
    final priorityStr = json['priority'] as String?;
    final priority = priorityStr != null
        ? SOSPriority.values.firstWhere(
            (p) => p.name == priorityStr,
            orElse: () => SOSPriority.high,
          )
        : SOSPriority.high;
    final createdAtVal = json['createdAt'];
    final createdAt = createdAtVal is num
        ? DateTime.fromMillisecondsSinceEpoch(createdAtVal.toInt())
        : DateTime.now();
    final assignedUnitId = json['assignedUnitId'] as String?;
    final prefLat = json['preferredFacilityLat'] is num
        ? (json['preferredFacilityLat'] as num).toDouble()
        : null;
    final prefLng = json['preferredFacilityLng'] is num
        ? (json['preferredFacilityLng'] as num).toDouble()
        : null;

    return SOSRequest(
      id: id,
      location: LatLng(lat, lng),
      citizenId: citizenId,
      citizenName: citizenName,
      message: json['message'] as String?,
      priority: priority,
      sosType: sosType,
      status: status,
      createdAt: createdAt,
      assignedUnitId: assignedUnitId,
      completedAt: completedAt,
      preferredFacilityId: json['preferredFacilityId'] as String?,
      preferredFacilityName: json['preferredFacilityName'] as String?,
      preferredFacilityLocation:
          (prefLat != null && prefLng != null) ? LatLng(prefLat, prefLng) : null,
      locationIsPinned: json['locationIsPinned'] == true,
      reportedForName: json['reportedForName'] as String?,
      callbackPhone: json['callbackPhone'] as String?,
      scenePhotoUrl: json['scenePhotoUrl'] as String?,
      barangayId: normalizeBarangayId(json['barangayId']?.toString()),
      assistingBarangayIds: _stringList(json['assistingBarangayIds']),
      assistingUnitTypes: _stringListMap(json['assistingUnitTypes']),
    );
  }
}

List<String> _stringList(dynamic raw) {
  final out = <String>[];
  if (raw is List) {
    for (final e in raw) {
      final id = e?.toString().trim() ?? '';
      if (id.isNotEmpty && !out.contains(id)) out.add(id);
    }
  }
  return out;
}

Map<String, List<String>> _stringListMap(dynamic raw) {
  final out = <String, List<String>>{};
  if (raw is Map) {
    for (final e in raw.entries) {
      final key = normalizeBarangayId(e.key.toString());
      out[key] = _stringList(e.value);
    }
  }
  return out;
}

class StandbyPoint {
  final String id;
  final String name;
  final LatLng position;
  final double coverageRadiusKm;
  final bool isNorthCaloocan;

  const StandbyPoint({
    required this.id,
    required this.name,
    required this.position,
    this.coverageRadiusKm = 2.0,
    required this.isNorthCaloocan,
  });
}

/// Traffic condition for a route segment (for map overlay).
enum TrafficLevel { clear, moderate, heavy }

/// A segment of the route with a traffic condition (green / orange / red).
class RouteTrafficSegment {
  final List<LatLng> points;
  final TrafficLevel level;

  const RouteTrafficSegment({required this.points, required this.level});
}

class RouteNode {
  final LatLng position;
  final double gCost;
  final double hCost;
  final RouteNode? parent;

  const RouteNode({
    required this.position,
    required this.gCost,
    required this.hCost,
    this.parent,
  });

  double get fCost => gCost + hCost;
}
