import 'package:flutter_test/flutter_test.dart';
import 'package:rescue_app/services/a_star_routing_service.dart';
import 'package:rescue_app/services/osrm_routing_service.dart';
import 'package:rescue_app/models/rescue_models.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('AStarRoutingService', () {
    const service = AStarRoutingService(stepKm: 0.15, maxIterations: 5000);

    test('finds route between two close points', () {
      final route = service.findRoute(
        start: const LatLng(14.6544, 120.9840),
        goal: const LatLng(14.6600, 120.9900),
        hazardZones: [],
      );
      expect(route, isNotEmpty);
      expect(route.first.latitude, closeTo(14.6544, 0.01));
      expect(route.last.latitude, closeTo(14.6600, 0.01));
    });

    test('avoids hazard zones', () {
      final hazard = HazardZone(
        id: 'hz-test',
        name: 'Test Hazard',
        type: HazardType.flood,
        polygon: const [
          LatLng(14.6560, 120.9860),
          LatLng(14.6560, 120.9880),
          LatLng(14.6580, 120.9880),
          LatLng(14.6580, 120.9860),
        ],
        severityWeight: 50.0,
        reportedAt: DateTime.now(),
      );

      final route = service.findRoute(
        start: const LatLng(14.6544, 120.9840),
        goal: const LatLng(14.6600, 120.9900),
        hazardZones: [hazard],
      );

      for (final point in route) {
        expect(hazard.containsPoint(point), isFalse);
      }
    });
  });

  group('OsrmRouteResult', () {
    test('empty result has correct defaults', () {
      final result = OsrmRouteResult.empty();
      expect(result.isEmpty, isTrue);
      expect(result.durationMinutes, 0);
      expect(result.distanceKm, 0);
    });
  });
}
