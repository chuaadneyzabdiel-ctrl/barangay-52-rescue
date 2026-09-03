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
    final frac = (remainingKm / osrmDistanceKm).clamp(0.0, 1.0);
    var baseEta = osrmEtaMinutes * frac;

    // Hybrid ETA priors from observed rides (free alternative to paid traffic APIs).
    final loc = _locationBucket(driverPosition);
    final tod = _timeBucket(DateTime.now().hour);
    final key = '${loc}_$tod';
    final baseSpeedKmh = _speedKmhPriors[key] ?? _speedKmhPriors['default']!;
    final stopRatio = _stopRatioPriors[key] ?? _stopRatioPriors['default']!;

    final spd = speedMps ?? 0.0;
    final effectiveStopped =
        secondsStopped > stoppedGraceSeconds ? secondsStopped - stoppedGraceSeconds : 0.0;

    // Blend live speed with context prior; when not moving, use prior.
    final liveKmh = (spd * 3.6);
    final hasLive = liveKmh >= 5.0;
    final blendedKmh = hasLive
        ? (0.70 * liveKmh + 0.30 * baseSpeedKmh)
        : baseSpeedKmh;
    final effectiveKmh = blendedKmh.clamp(8.0, 70.0);

    final movingMin = (remainingKm / effectiveKmh) * 60.0;
    var hybridEta = movingMin + (movingMin * stopRatio);

    // While stopped, apply bounded creep so ETA remains realistic and responsive.
    final creep = min(maxStoppedCreepMinutes, effectiveStopped * 0.02);
    hybridEta += creep;

    // Keep a small weight of OSRM proportional ETA for stability.
    final out = 0.85 * hybridEta + 0.15 * baseEta;
    return out.clamp(0.5, 999.0);
  }

  static const Map<String, double> _speedKmhPriors = {
    // Initial priors from gathered rides (can be tuned over time).
    'caloocan_morning': 21.0,
    'caloocan_lunch': 19.0,
    'caloocan_evening': 17.5,
    'valenzuela_morning': 22.0,
    'valenzuela_lunch': 20.5,
    'valenzuela_evening': 18.5,
    'default': 18.5,
  };

  static const Map<String, double> _stopRatioPriors = {
    'caloocan_morning': 0.12,
    'caloocan_lunch': 0.18,
    'caloocan_evening': 0.24,
    'valenzuela_morning': 0.09,
    'valenzuela_lunch': 0.14,
    'valenzuela_evening': 0.20,
    'default': 0.15,
  };

  static String _timeBucket(int hour) {
    if (hour >= 5 && hour <= 10) return 'morning';
    if (hour >= 11 && hour <= 14) return 'lunch';
    if (hour >= 15 && hour <= 20) return 'evening';
    return 'night';
  }

  static String _locationBucket(LatLng p) {
    // Broad geofence buckets for priors. Falls back to default elsewhere.
    final inCaloocan =
        p.latitude >= 14.62 && p.latitude <= 14.79 && p.longitude >= 120.96 && p.longitude <= 121.08;
    if (inCaloocan) return 'caloocan';
    final inValenzuela =
        p.latitude >= 14.64 && p.latitude <= 14.76 && p.longitude >= 120.90 && p.longitude <= 121.04;
    if (inValenzuela) return 'valenzuela';
    return 'default';
  }
}
