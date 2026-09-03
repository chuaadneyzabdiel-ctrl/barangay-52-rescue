import 'dart:math';

import 'package:latlong2/latlong.dart';

import '../models/rescue_models.dart';
import '../utils/route_geo_utils.dart';

/// Live ETA for responder navigation: remaining distance, mock traffic weighting,
/// GPS speed, and stopped-time creep (OSRM alone is free-flow only).
class NavigationEtaCalculator {
  NavigationEtaCalculator._();

  /// Minimum speed (m/s) to treat as "moving" for ETA.
  static const double movingThresholdMps = 1.0;

  /// Seconds stopped before we add noticeable creep (avoid GPS noise).
  static const double stoppedGraceSeconds = 3.0;

  /// Max extra minutes added while stopped (traffic / unknown delay).
  static const double maxStoppedCreepMinutes = 12.0;

  /// Computes display ETA in minutes.
  static double computeLiveEtaMinutes({
    required List<LatLng> osrmRoute,
    required List<RouteTrafficSegment> trafficSegments,
    required double osrmEtaMinutes,
    required double osrmDistanceKm,
    required LatLng driverPosition,
    double? speedMps,
    double secondsStopped = 0,
  }) {
    if (osrmRoute.length < 2 || osrmDistanceKm <= 0) {
      return osrmEtaMinutes.clamp(0.0, 9999.0);
    }

    final remainingKm =
        RouteGeoUtils.remainingDistanceKm(driverPosition, osrmRoute);
    if (remainingKm < 0.015) {
      return 0;
    }

    final trafficMult = RouteGeoUtils.trafficMultiplierRemaining(
      driverPosition,
      osrmRoute,
      trafficSegments,
    );

    // Proportional OSRM time over remaining distance, scaled by mock traffic.
    final frac = (remainingKm / osrmDistanceKm).clamp(0.0, 1.0);
    var baseEta = osrmEtaMinutes * frac * trafficMult;

    final spd = speedMps ?? 0.0;
    final effectiveStopped =
        secondsStopped > stoppedGraceSeconds ? secondsStopped - stoppedGraceSeconds : 0.0;

    if (spd >= movingThresholdMps) {
      // Moving: prefer time from remaining distance / current speed (km/h).
      final speedKmh = (spd * 3.6).clamp(5.0, 130.0);
      final etaFromSpeed = (remainingKm / speedKmh) * 60.0;
      // Blend with traffic-adjusted OSRM so we don't jump wildly when GPS speed flickers.
      final blended = 0.65 * etaFromSpeed + 0.35 * baseEta;
      return blended.clamp(0.5, 999.0);
    }

    // Stopped / crawling: creep ETA so it doesn't look frozen; cap extra delay.
    // ~0.02 min added per second stopped (after grace) — visible creep without exploding ETA.
    final creep =
        min(maxStoppedCreepMinutes, effectiveStopped * 0.02);
    baseEta += creep;
    return baseEta.clamp(0.5, 999.0);
  }
}
