import 'package:latlong2/latlong.dart';
import '../models/map_layer_models.dart';
import 'geo_utils.dart';

/// Shared facility search helpers used by both citizen and responder UIs.
class FacilitySearchUtils {
  static String normalize(String value) {
    var v = value.toLowerCase();
    v = v.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    v = v.replaceAll(RegExp(r'\s+'), ' ');
    // common local synonyms / variants
    v = v.replaceAll('ob gyn', 'obgyn');
    v = v.replaceAll('ob-gyne', 'obgyn');
    v = v.replaceAll('ob gyne', 'obgyn');
    v = v.replaceAll('bahay paanakan', 'lying in');
    v = v.replaceAll('lying-in', 'lying in');
    v = v.replaceAll('3 s', '3s');
    v = v.replaceAll('3s center', '3s');
    return v;
  }

  static bool matches(MapLayerPOI poi, String query) {
    final qNorm = normalize(query);
    if (qNorm.isEmpty) return true;

    final nameNorm = normalize(poi.name);
    final subtitleNorm = normalize(poi.subtitle ?? '');
    final typeNorm = normalize(poi.facilityType ?? '');
    final cityNorm = normalize(poi.city ?? '');
    final addressNorm = normalize(poi.address ?? '');

    return nameNorm.contains(qNorm) ||
        subtitleNorm.contains(qNorm) ||
        typeNorm.contains(qNorm) ||
        cityNorm.contains(qNorm) ||
        addressNorm.contains(qNorm);
  }

  static MapLayerPOI? nearestTo(LatLng origin, List<MapLayerPOI> facilities) {
    if (facilities.isEmpty) return null;
    MapLayerPOI? best;
    var bestKm = double.infinity;
    for (final p in facilities) {
      final km = GeoUtils.haversineKm(origin, p.position);
      if (km < bestKm) {
        bestKm = km;
        best = p;
      }
    }
    return best;
  }

  static List<MapLayerPOI> sortedByDistance(
    LatLng origin,
    Iterable<MapLayerPOI> facilities,
  ) {
    final rows = List<MapLayerPOI>.from(facilities);
    rows.sort(
      (a, b) => GeoUtils.haversineKm(origin, a.position)
          .compareTo(GeoUtils.haversineKm(origin, b.position)),
    );
    return rows;
  }

  static String formatDistanceKm(double km) {
    if (km < 1) return '${(km * 1000).round()} m';
    return '${km.toStringAsFixed(1)} km';
  }
}

