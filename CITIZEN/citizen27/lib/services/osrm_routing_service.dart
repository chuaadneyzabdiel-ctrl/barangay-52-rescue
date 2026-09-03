import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/osrm_navigation_models.dart';

/// Calls the public OSRM API to obtain real road-following routes.
/// No API key or account required.
///
/// Use alongside [AStarRoutingService]: A* handles hazard avoidance logic,
/// OSRM provides road-accurate geometry for display.
class OsrmRoutingService {
  static const _baseUrl = 'http://router.project-osrm.org';

  final http.Client _client;

  OsrmRoutingService({http.Client? client}) : _client = client ?? http.Client();

  /// Snaps an arbitrary point to the nearest routable road location.
  /// Returns the snapped coordinate, or the original point on failure.
  Future<LatLng> nearest(LatLng point) async {
    final url = Uri.parse(
      '$_baseUrl/nearest/v1/driving/'
      '${point.longitude},${point.latitude}'
      '?number=1',
    );
    try {
      final response = await _client.get(url).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return point;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['code'] != 'Ok') return point;
      final waypoints = json['waypoints'] as List?;
      if (waypoints == null || waypoints.isEmpty) return point;
      final wp0 = waypoints.first as Map<String, dynamic>;
      final loc = wp0['location'] as List?;
      if (loc == null || loc.length < 2) return point;
      return LatLng((loc[1] as num).toDouble(), (loc[0] as num).toDouble());
    } catch (_) {
      return point;
    }
  }

  /// Fetches a driving route between [start] and [end].
  /// Returns the decoded polyline as a list of [LatLng], or empty on failure.
  Future<OsrmRouteResult> getRoute(LatLng start, LatLng end) async {
    final list = await getRouteWithAlternatives(start, end);
    return list.isNotEmpty ? list.first : OsrmRouteResult.empty();
  }

  /// Fetches driving route(s) with optional alternatives (primary first, then alternates).
  Future<List<OsrmRouteResult>> getRouteWithAlternatives(LatLng start, LatLng end) async {
    final url = Uri.parse(
      '$_baseUrl/route/v1/driving/'
      '${start.longitude},${start.latitude};'
      '${end.longitude},${end.latitude}'
      '?overview=full&geometries=geojson&steps=true&alternatives=true',
    );

    try {
      final response = await _client.get(url).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode != 200) return [];

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['code'] != 'Ok') return [];

      final routes = json['routes'] as List?;
      if (routes == null || routes.isEmpty) return [];

      final results = <OsrmRouteResult>[];
      for (final r in routes) {
        final route = r as Map<String, dynamic>;
        final geometry = route['geometry'] as Map<String, dynamic>?;
        if (geometry == null) continue;
        final coords = geometry['coordinates'] as List?;
        if (coords == null || coords.isEmpty) continue;
        final points = coords
            .map((c) => LatLng(
                  (c[1] as num).toDouble(),
                  (c[0] as num).toDouble(),
                ))
            .toList();
        final durationSec = (route['duration'] as num?)?.toDouble() ?? 0.0;
        final distanceMeters = (route['distance'] as num?)?.toDouble() ?? 0.0;
        final navSteps = parseOsrmNavigationSteps(route);
        results.add(OsrmRouteResult(
          points: points,
          durationSeconds: durationSec,
          distanceMeters: distanceMeters,
          navigationSteps: navSteps,
        ));
      }
      return results;
    } catch (_) {
      return [];
    }
  }

  /// Fetches a route through multiple waypoints in order.
  Future<OsrmRouteResult> getRouteViaWaypoints(List<LatLng> waypoints) async {
    if (waypoints.length < 2) return OsrmRouteResult.empty();

    final coordString = waypoints
        .map((p) => '${p.longitude},${p.latitude}')
        .join(';');

    final url = Uri.parse(
      '$_baseUrl/route/v1/driving/$coordString'
      '?overview=full&geometries=geojson&steps=true',
    );

    try {
      final response = await _client.get(url).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode != 200) return OsrmRouteResult.empty();

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['code'] != 'Ok') return OsrmRouteResult.empty();

      final routes = json['routes'] as List;
      if (routes.isEmpty) return OsrmRouteResult.empty();

      final route = routes[0] as Map<String, dynamic>;
      final geometry = route['geometry'] as Map<String, dynamic>;
      final coords = geometry['coordinates'] as List;

      final points = coords
          .map((c) => LatLng(
                (c[1] as num).toDouble(),
                (c[0] as num).toDouble(),
              ))
          .toList();

      return OsrmRouteResult(
        points: points,
        durationSeconds: (route['duration'] as num).toDouble(),
        distanceMeters: (route['distance'] as num).toDouble(),
        navigationSteps: parseOsrmNavigationSteps(route),
      );
    } catch (_) {
      return OsrmRouteResult.empty();
    }
  }

  void dispose() {
    _client.close();
  }
}

List<OsrmNavigationStep> parseOsrmNavigationSteps(
  Map<String, dynamic> routeJson,
) {
  final legs = routeJson['legs'] as List?;
  if (legs == null || legs.isEmpty) return [];
  final leg0 = legs[0] as Map<String, dynamic>;
  final steps = leg0['steps'] as List?;
  if (steps == null) return [];
  return steps
      .map((s) => OsrmNavigationStep.fromOsrmJson(
            Map<String, dynamic>.from(s as Map),
          ))
      .toList();
}

class OsrmRouteResult {
  final List<LatLng> points;
  final double durationSeconds;
  final double distanceMeters;
  final List<OsrmNavigationStep> navigationSteps;

  const OsrmRouteResult({
    required this.points,
    required this.durationSeconds,
    required this.distanceMeters,
    this.navigationSteps = const [],
  });

  factory OsrmRouteResult.empty() => const OsrmRouteResult(
        points: [],
        durationSeconds: 0,
        distanceMeters: 0,
        navigationSteps: [],
      );

  bool get isEmpty => points.isEmpty;
  double get durationMinutes => durationSeconds / 60.0;
  double get distanceKm => distanceMeters / 1000.0;
}
