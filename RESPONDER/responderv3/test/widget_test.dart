import 'package:flutter_test/flutter_test.dart';
import 'package:rescue_app/services/a_star_routing_service.dart';
import 'package:rescue_app/services/osrm_routing_service.dart';
import 'package:rescue_app/models/rescue_models.dart';
import 'package:rescue_app/utils/password_utils.dart';
import 'package:rescue_app/utils/unit_sos_compatibility.dart';
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

  group('PasswordUtils', () {
    test('hash/verify works with salt', () {
      final salt = PasswordUtils.generateSalt();
      final hash = PasswordUtils.hashPassword(
        password: 'TempPass123',
        salt: salt,
      );
      expect(
        PasswordUtils.verifyPassword(
          password: 'TempPass123',
          salt: salt,
          expectedHash: hash,
        ),
        isTrue,
      );
      expect(
        PasswordUtils.verifyPassword(
          password: 'wrong',
          salt: salt,
          expectedHash: hash,
        ),
        isFalse,
      );
    });

    test('password policy checks complexity', () {
      expect(PasswordUtils.isStrongEnough('short1A'), isFalse);
      expect(PasswordUtils.isStrongEnough('alllowercase123'), isFalse);
      expect(PasswordUtils.isStrongEnough('ALLUPPERCASE123'), isFalse);
      expect(PasswordUtils.isStrongEnough('ValidPass123'), isTrue);
    });
  });

  group('Unit/SOS compatibility', () {
    test('fire unit cannot accept medical SOS', () {
      expect(
        canUnitHandleSos(UnitType.fireTruck, SOSType.medical),
        isFalse,
      );
    });

    test('ambulance unit cannot accept fire SOS', () {
      expect(
        canUnitHandleSos(UnitType.ambulance, SOSType.fire),
        isFalse,
      );
    });

    test('compatible combinations still pass', () {
      expect(
        canUnitHandleSos(UnitType.ambulance, SOSType.medical),
        isTrue,
      );
      expect(
        canUnitHandleSos(UnitType.fireTruck, SOSType.fire),
        isTrue,
      );
      expect(
        canUnitHandleSos(UnitType.rescue, SOSType.flood),
        isTrue,
      );
    });
  });
}
