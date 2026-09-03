import 'package:latlong2/latlong.dart';

import '../models/osrm_navigation_models.dart';
import 'route_geo_utils.dart';

/// Computes the next maneuver text and distance from OSRM steps + live position.
NavigationGuidance? computeNavigationGuidance({
  required List<OsrmNavigationStep> steps,
  required LatLng driver,
  required List<LatLng> route,
}) {
  if (steps.isEmpty || route.length < 2) return null;

  final alongM =
      RouteGeoUtils.distanceAlongRouteKm(driver, route) * 1000.0;
  if (alongM.isNaN || alongM < 0) return null;

  var cum = 0.0;
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final d = step.distanceMeters;
    final segEnd = cum + d;

    if (alongM < segEnd) {
      // Inside step i — next maneuver is at end of this step (start of next).
      if (i < steps.length - 1) {
        final next = steps[i + 1];
        final distM = segEnd - alongM;
        return NavigationGuidance(
          nextInstruction: next.instructionText,
          distanceToNextLabel: _formatDistanceMeters(distM),
          distanceToNextManeuverKm: distM / 1000.0,
        );
      }
      // Last step
      final distM = segEnd - alongM;
      return NavigationGuidance(
        nextInstruction: 'Arrive at destination',
        distanceToNextLabel: _formatDistanceMeters(distM),
        distanceToNextManeuverKm: distM / 1000.0,
      );
    }
    cum = segEnd;
  }

  // Past all steps — treat as arrival
  return const NavigationGuidance(
    nextInstruction: 'Arrive at destination',
    distanceToNextLabel: '0 m',
    distanceToNextManeuverKm: 0,
  );
}

String _formatDistanceMeters(double m) {
  if (m < 1000) {
    return '${m.round()} m';
  }
  return '${(m / 1000.0).toStringAsFixed(1)} km';
}
