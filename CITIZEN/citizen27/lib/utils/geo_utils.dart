import 'dart:math';
import 'package:latlong2/latlong.dart';

class GeoUtils {
  static const double earthRadiusKm = 6371.0;

  /// Haversine distance in kilometers between two points.
  static double haversineKm(LatLng a, LatLng b) {
    final dLat = _toRadians(b.latitude - a.latitude);
    final dLng = _toRadians(b.longitude - a.longitude);
    final sinDLat = sin(dLat / 2);
    final sinDLng = sin(dLng / 2);
    final h = sinDLat * sinDLat +
        cos(_toRadians(a.latitude)) *
            cos(_toRadians(b.latitude)) *
            sinDLng *
            sinDLng;
    return 2 * earthRadiusKm * asin(sqrt(h));
  }

  /// Bearing from point a to point b in degrees.
  static double bearing(LatLng a, LatLng b) {
    final dLng = _toRadians(b.longitude - a.longitude);
    final y = sin(dLng) * cos(_toRadians(b.latitude));
    final x = cos(_toRadians(a.latitude)) * sin(_toRadians(b.latitude)) -
        sin(_toRadians(a.latitude)) *
            cos(_toRadians(b.latitude)) *
            cos(dLng);
    return (_toDegrees(atan2(y, x)) + 360) % 360;
  }

  /// Returns a point at [distanceKm] from [origin] along [bearingDeg].
  static LatLng destinationPoint(
      LatLng origin, double distanceKm, double bearingDeg) {
    final d = distanceKm / earthRadiusKm;
    final brng = _toRadians(bearingDeg);
    final lat1 = _toRadians(origin.latitude);
    final lng1 = _toRadians(origin.longitude);

    final lat2 = asin(
        sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(brng));
    final lng2 = lng1 +
        atan2(sin(brng) * sin(d) * cos(lat1),
            cos(d) - sin(lat1) * sin(lat2));

    return LatLng(_toDegrees(lat2), _toDegrees(lng2));
  }

  /// Generates neighbor grid nodes around [center] at [stepKm] distance.
  static List<LatLng> gridNeighbors(LatLng center, double stepKm) {
    const bearings = [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0];
    return bearings
        .map((b) => destinationPoint(center, stepKm, b))
        .toList();
  }

  static double _toRadians(double deg) => deg * pi / 180;
  static double _toDegrees(double rad) => rad * 180 / pi;
}
