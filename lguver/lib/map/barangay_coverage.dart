import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Barangay 52, Grace Park West, Caloocan (OSM relation 3400327).
/// Add more polygons here when other barangays join the system.
class BarangayCoverage {
  static const String name = 'Barangay 52';

  static const LatLng center = LatLng(14.6470319, 120.9768745);

  static const List<LatLng> polygon = [
    LatLng(14.6475339, 120.9757352),
    LatLng(14.6463998, 120.9759590),
    LatLng(14.6464535, 120.9764155),
    LatLng(14.6464632, 120.9768166),
    LatLng(14.6464672, 120.9769807),
    LatLng(14.6464788, 120.9774604),
    LatLng(14.6464877, 120.9778235),
    LatLng(14.6475034, 120.9778514),
    LatLng(14.6475423, 120.9778525),
    LatLng(14.6475459, 120.9774894),
    LatLng(14.6475491, 120.9771847),
    LatLng(14.6475518, 120.9769225),
    LatLng(14.6475539, 120.9767465),
    LatLng(14.6475579, 120.9763261),
  ];

  static bool contains(LatLng point) {
    int crossings = 0;
    for (int i = 0; i < polygon.length; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % polygon.length];
      if ((a.latitude <= point.latitude && b.latitude > point.latitude) ||
          (b.latitude <= point.latitude && a.latitude > point.latitude)) {
        final t = (point.latitude - a.latitude) / (b.latitude - a.latitude);
        if (point.longitude < a.longitude + t * (b.longitude - a.longitude)) {
          crossings++;
        }
      }
    }
    return crossings.isOdd;
  }

  static List<Widget> mapLayers() => [
        PolygonLayer(
          polygons: [
            Polygon(
              points: polygon,
              color: const Color(0x3327AE60),
              borderColor: const Color(0xFF27AE60),
              borderStrokeWidth: 3,
            ),
          ],
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: center,
              width: 108,
              height: 26,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xCC1B3A5C),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Center(
                    child: Text(
                      'Barangay 52',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ];
}
