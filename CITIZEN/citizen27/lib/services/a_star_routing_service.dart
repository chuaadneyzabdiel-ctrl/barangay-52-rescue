import 'dart:collection';
import 'package:latlong2/latlong.dart';
import '../models/rescue_models.dart';
import '../utils/geo_utils.dart';

/// A* pathfinding service that computes optimal rescue routes while
/// respecting dynamic hazard zones (floods, fires, etc.) set by the LGU.
///
/// The grid resolution [stepKm] controls the spacing between graph nodes.
/// Smaller values yield more accurate routes but increase computation time.
class AStarRoutingService {
  final double stepKm;
  final int maxIterations;

  const AStarRoutingService({
    this.stepKm = 0.15,
    this.maxIterations = 10000,
  });

  /// Computes the optimal route from [start] to [goal] while avoiding
  /// active [hazardZones].
  ///
  /// Returns a list of [LatLng] waypoints from start to goal, or an empty
  /// list if no path is found within [maxIterations].
  List<LatLng> findRoute({
    required LatLng start,
    required LatLng goal,
    required List<HazardZone> hazardZones,
  }) {
    final activeHazards = hazardZones.where((z) => z.isActive).toList();
    final goalThreshold = stepKm * 1.2;

    final openSet = SplayTreeSet<RouteNode>(
      (a, b) {
        final cmp = a.fCost.compareTo(b.fCost);
        if (cmp != 0) return cmp;
        return a.hCost.compareTo(b.hCost);
      },
    );

    final visited = <String, double>{};

    final startNode = RouteNode(
      position: start,
      gCost: 0,
      hCost: _heuristic(start, goal),
    );
    openSet.add(startNode);
    visited[_gridKey(start)] = 0;

    int iterations = 0;

    while (openSet.isNotEmpty && iterations < maxIterations) {
      iterations++;
      final current = openSet.first;
      openSet.remove(current);

      if (GeoUtils.haversineKm(current.position, goal) <= goalThreshold) {
        return _reconstructPath(current, goal);
      }

      final neighbors = GeoUtils.gridNeighbors(current.position, stepKm);

      for (final neighborPos in neighbors) {
        if (_isInHazardZone(neighborPos, activeHazards)) {
          continue;
        }

        final moveCost = _edgeCost(current.position, neighborPos, activeHazards);
        final tentativeG = current.gCost + moveCost;
        final key = _gridKey(neighborPos);

        if (visited.containsKey(key) && visited[key]! <= tentativeG) {
          continue;
        }

        visited[key] = tentativeG;

        final neighborNode = RouteNode(
          position: neighborPos,
          gCost: tentativeG,
          hCost: _heuristic(neighborPos, goal),
          parent: current,
        );
        openSet.add(neighborNode);
      }
    }

    return [];
  }

  /// h(n): Haversine straight-line distance — admissible and consistent.
  double _heuristic(LatLng from, LatLng to) {
    return GeoUtils.haversineKm(from, to);
  }

  /// Edge cost with proximity penalty near hazard zones.
  double _edgeCost(LatLng from, LatLng to, List<HazardZone> hazards) {
    double baseCost = GeoUtils.haversineKm(from, to);
    double penalty = 0;

    for (final hazard in hazards) {
      final midpoint = LatLng(
        (from.latitude + to.latitude) / 2,
        (from.longitude + to.longitude) / 2,
      );
      for (final vertex in hazard.polygon) {
        final dist = GeoUtils.haversineKm(midpoint, vertex);
        if (dist < stepKm * 3) {
          penalty += hazard.severityWeight.isFinite
              ? hazard.severityWeight * (1.0 / (dist + 0.01))
              : 1000.0 * (1.0 / (dist + 0.01));
        }
      }
    }

    return baseCost + penalty;
  }

  bool _isInHazardZone(LatLng point, List<HazardZone> hazards) {
    return hazards.any((h) => h.containsPoint(point));
  }

  String _gridKey(LatLng pos) {
    final latKey = (pos.latitude / (stepKm / 111.0)).round();
    final lngKey = (pos.longitude / (stepKm / 111.0)).round();
    return '$latKey,$lngKey';
  }

  List<LatLng> _reconstructPath(RouteNode endNode, LatLng goal) {
    final path = <LatLng>[];
    RouteNode? current = endNode;
    while (current != null) {
      path.add(current.position);
      current = current.parent;
    }
    path.add(goal);
    return path.reversed.toList();
  }
}
