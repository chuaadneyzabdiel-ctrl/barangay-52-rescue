import 'dart:math';

import 'package:latlong2/latlong.dart';

import '../models/rescue_models.dart';
import 'geo_utils.dart';

/// Geometry along a route polyline (remaining distance, traffic weighting).
class RouteGeoUtils {
  RouteGeoUtils._();

  /// Total length of a polyline in km.
  static double polylineLengthKm(List<LatLng> route) {
    if (route.length < 2) return 0;
    var s = 0.0;
    for (var i = 0; i < route.length - 1; i++) {
      s += GeoUtils.haversineKm(route[i], route[i + 1]);
    }
    return s;
  }

  /// Closest point on segment [a]–[b] to [p] (planar lon/lat approx — fine for city scale).
  static LatLng closestPointOnSegment(LatLng p, LatLng a, LatLng b) {
    final ax = a.longitude;
    final ay = a.latitude;
    final bx = b.longitude;
    final by = b.latitude;
    final px = p.longitude;
    final py = p.latitude;
    final abx = bx - ax;
    final aby = by - ay;
    final apx = px - ax;
    final apy = py - ay;
    final denom = abx * abx + aby * aby;
    final t = denom <= 1e-18 ? 0.0 : ((apx * abx + apy * aby) / denom).clamp(0.0, 1.0);
    return LatLng(ay + t * aby, ax + t * abx);
  }

  /// Distance in km along [route] from the first point to the projection of [p] onto the polyline.
  static double distanceAlongRouteKm(LatLng p, List<LatLng> route) {
    if (route.length < 2) return 0;
    var alongBeforeSeg = 0.0;
    var bestDist = double.infinity;
    var bestAlong = 0.0;
    for (var i = 0; i < route.length - 1; i++) {
      final a = route[i];
      final b = route[i + 1];
      final segLen = GeoUtils.haversineKm(a, b);
      final c = closestPointOnSegment(p, a, b);
      final d = GeoUtils.haversineKm(p, c);
      final t = segLen <= 1e-9 ? 0.0 : GeoUtils.haversineKm(a, c) / segLen;
      final projAlong = alongBeforeSeg + t * segLen;
      if (d < bestDist) {
        bestDist = d;
        bestAlong = projAlong;
      }
      alongBeforeSeg += segLen;
    }
    return bestAlong;
  }

  /// Remaining distance (km) from driver's projected position to the end of the route.
  static double remainingDistanceKm(LatLng driver, List<LatLng> route) {
    final total = polylineLengthKm(route);
    if (total <= 0) return 0;
    final along = distanceAlongRouteKm(driver, route);
    return max(0.0, total - along);
  }

  /// Polyline from the driver's projection on [route] to the destination.
  /// Drops already-passed geometry so arrows/line aren't left behind.
  static List<LatLng> remainingPolyline(LatLng driver, List<LatLng> route) {
    if (route.length < 2) return List<LatLng>.from(route);
    var bestI = 0;
    var bestDist = double.infinity;
    LatLng bestProj = route.first;
    for (var i = 0; i < route.length - 1; i++) {
      final a = route[i];
      final b = route[i + 1];
      final c = closestPointOnSegment(driver, a, b);
      final d = GeoUtils.haversineKm(driver, c);
      if (d < bestDist) {
        bestDist = d;
        bestI = i;
        bestProj = c;
      }
    }
    // If far off the road, keep full route until a reroute replaces it.
    if (bestDist > 0.15) return List<LatLng>.from(route);
    final rest = route.sublist(bestI + 1);
    if (rest.isEmpty) return [bestProj, route.last];
    // Avoid duplicate first vertex when projection ≈ segment end.
    if (GeoUtils.haversineKm(bestProj, rest.first) < 0.005) {
      return rest;
    }
    return [bestProj, ...rest];
  }

  static double _levelMultiplier(TrafficLevel level) {
    switch (level) {
      case TrafficLevel.clear:
        return 1.0;
      case TrafficLevel.moderate:
        return 1.45;
      case TrafficLevel.heavy:
        return 2.05;
    }
  }

  /// Average traffic delay multiplier along the part of the route still ahead of the driver.
  static double trafficMultiplierRemaining(
    LatLng driver,
    List<LatLng> route,
    List<RouteTrafficSegment> segments,
  ) {
    if (route.isEmpty || segments.isEmpty) return 1.0;
    final total = polylineLengthKm(route);
    if (total <= 0) return 1.0;
    final along = distanceAlongRouteKm(driver, route);
    final remainingKm = max(0.0, total - along);
    if (remainingKm < 1e-6) return 1.0;

    var cursor = 0.0;
    var weighted = 0.0;
    var weight = 0.0;
    for (final seg in segments) {
      final len = polylineLengthKm(seg.points);
      if (len <= 0) {
        continue;
      }
      final segStart = cursor;
      final segEnd = cursor + len;
      final m = _levelMultiplier(seg.level);
      final ovStart = max(along, segStart);
      final ovEnd = min(segEnd, total);
      final ov = max(0.0, ovEnd - ovStart);
      if (ov > 0) {
        weighted += ov * m;
        weight += ov;
      }
      cursor = segEnd;
    }
    if (weight <= 0) return 1.0;
    return weighted / weight;
  }
}
