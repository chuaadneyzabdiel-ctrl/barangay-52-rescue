import 'dart:math';
import 'package:latlong2/latlong.dart';
import '../models/rescue_models.dart';
import '../utils/geo_utils.dart';

/// Suggests optimal standby locations for idle rescue units based on real-time
/// incident density and the non-contiguous geography of North/South Caloocan.
class DynamicRelocationService {
  static final List<StandbyPoint> candidatePoints = [
    // --- North Caloocan ---
    const StandbyPoint(
      id: 'sp-n1',
      name: 'Bagumbong Fire Station Area',
      position: LatLng(14.7590, 121.0420),
      isNorthCaloocan: true,
    ),
    const StandbyPoint(
      id: 'sp-n2',
      name: 'Camarin Junction',
      position: LatLng(14.7510, 121.0560),
      isNorthCaloocan: true,
    ),
    const StandbyPoint(
      id: 'sp-n3',
      name: 'Llano Road Corridor',
      position: LatLng(14.7440, 121.0480),
      isNorthCaloocan: true,
    ),
    const StandbyPoint(
      id: 'sp-n4',
      name: 'Deparo Central',
      position: LatLng(14.7350, 121.0350),
      isNorthCaloocan: true,
    ),
    // --- South Caloocan ---
    const StandbyPoint(
      id: 'sp-s1',
      name: 'Monumento Circle',
      position: LatLng(14.6544, 120.9840),
      isNorthCaloocan: false,
    ),
    const StandbyPoint(
      id: 'sp-s2',
      name: 'Grace Park Area',
      position: LatLng(14.6480, 120.9870),
      isNorthCaloocan: false,
    ),
    const StandbyPoint(
      id: 'sp-s3',
      name: 'Sangandaan Intersection',
      position: LatLng(14.6610, 120.9770),
      isNorthCaloocan: false,
    ),
    const StandbyPoint(
      id: 'sp-s4',
      name: '5th Avenue Corridor',
      position: LatLng(14.6420, 120.9750),
      isNorthCaloocan: false,
    ),
  ];

  Map<String, StandbyPoint> suggestRelocations({
    required List<RescueUnit> allUnits,
    required List<SOSRequest> activeIncidents,
    List<HazardZone> hazardZones = const [],
  }) {
    final idleUnits = allUnits.where((u) => u.isAvailable).toList();
    if (idleUnits.isEmpty) return {};

    final busyPositions = allUnits
        .where((u) => !u.isAvailable)
        .map((u) => u.position)
        .toList();

    final scoredPoints = _scoreCandidates(
      candidates: candidatePoints,
      busyPositions: busyPositions,
      idlePositions: idleUnits.map((u) => u.position).toList(),
      incidents: activeIncidents,
      hazardZones: hazardZones,
    );

    final assignments = <String, StandbyPoint>{};
    final assignedPointIds = <String>{};

    for (final entry in scoredPoints) {
      if (assignedPointIds.length >= idleUnits.length) break;

      final point = entry.key;
      if (assignedPointIds.contains(point.id)) continue;

      RescueUnit? bestUnit;
      double bestDist = double.infinity;

      for (final unit in idleUnits) {
        if (assignments.containsKey(unit.id)) continue;
        final d = GeoUtils.haversineKm(unit.position, point.position);
        if (d < bestDist) {
          bestDist = d;
          bestUnit = unit;
        }
      }

      if (bestUnit != null) {
        assignments[bestUnit.id] = point;
        assignedPointIds.add(point.id);
      }
    }

    return assignments;
  }

  List<MapEntry<StandbyPoint, double>> _scoreCandidates({
    required List<StandbyPoint> candidates,
    required List<LatLng> busyPositions,
    required List<LatLng> idlePositions,
    required List<SOSRequest> incidents,
    required List<HazardZone> hazardZones,
  }) {
    final allOccupied = [...busyPositions, ...idlePositions];

    final scored = <MapEntry<StandbyPoint, double>>[];
    for (final candidate in candidates) {
      final inHazard = hazardZones
          .where((h) => h.isActive)
          .any((h) => h.containsPoint(candidate.position));
      if (inHazard) continue;

      double score = 0;

      double minDistToUnit = double.infinity;
      for (final pos in allOccupied) {
        final d = GeoUtils.haversineKm(candidate.position, pos);
        minDistToUnit = min(minDistToUnit, d);
      }
      score += minDistToUnit * 10.0;

      for (final incident in incidents) {
        if (!incident.isActive) continue;
        final d = GeoUtils.haversineKm(candidate.position, incident.location);
        if (d < candidate.coverageRadiusKm * 2) {
          score += (candidate.coverageRadiusKm * 2 - d) * 5.0;
        }
      }

      final unitsInSameDistrict = allOccupied.where((pos) {
        final isNorth = pos.latitude > 14.70;
        return isNorth == candidate.isNorthCaloocan;
      }).length;
      if (unitsInSameDistrict == 0) {
        score += 20.0;
      }

      scored.add(MapEntry(candidate, score));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored;
  }
}
