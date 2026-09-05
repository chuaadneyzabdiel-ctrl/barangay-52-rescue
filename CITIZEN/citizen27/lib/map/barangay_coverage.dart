import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/barangay.dart';

/// OSM barangay boundary (Grace Park West, Caloocan).
class BarangayCoverageArea {
  final String id;
  final String name;
  final int osmRelationId;
  final LatLng center;
  final List<LatLng> polygon;
  final Color fillColor;
  final Color borderColor;

  const BarangayCoverageArea({
    required this.id,
    required this.name,
    required this.osmRelationId,
    required this.center,
    required this.polygon,
    required this.fillColor,
    required this.borderColor,
  });
}

/// Coverage geofences for barangays 52–56.
///
/// Barangay 52 keeps OSM relation 3400327 exactly as originally mapped.
/// 53–56 use the official OSM outer rings (3400328, 3400329, 3400330, 3400307).
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

  static const BarangayCoverageArea area52 = BarangayCoverageArea(
    id: '52',
    name: 'Barangay 52',
    osmRelationId: 3400327,
    center: center,
    polygon: polygon,
    fillColor: Color(0x3327AE60),
    borderColor: Color(0xFF27AE60),
  );

  static const BarangayCoverageArea area53 = BarangayCoverageArea(
    id: '53',
    name: 'Barangay 53',
    osmRelationId: 3400328,
    center: LatLng(14.6459011, 120.9783944),
    polygon: [
      LatLng(14.6447789, 120.9777535),
      LatLng(14.6446810, 120.9778448),
      LatLng(14.6446315, 120.9784684),
      LatLng(14.6446084, 120.9791000),
      LatLng(14.6446031, 120.9791998),
      LatLng(14.6446806, 120.9792022),
      LatLng(14.6453294, 120.9792235),
      LatLng(14.6460873, 120.9792466),
      LatLng(14.6475082, 120.9792933),
      LatLng(14.6475291, 120.9785594),
      LatLng(14.6475392, 120.9779205),
      LatLng(14.6475423, 120.9778525),
      LatLng(14.6475034, 120.9778514),
      LatLng(14.6464877, 120.9778235),
      LatLng(14.6461350, 120.9778112),
      LatLng(14.6457724, 120.9777958),
      LatLng(14.6449017, 120.9777587),
    ],
    fillColor: Color(0x3329B6F6),
    borderColor: Color(0xFF29B6F6),
  );

  static const BarangayCoverageArea area54 = BarangayCoverageArea(
    id: '54',
    name: 'Barangay 54',
    osmRelationId: 3400329,
    center: LatLng(14.6467237, 120.9817668),
    polygon: [
      LatLng(14.6460873, 120.9792466),
      LatLng(14.6460631, 120.9799779),
      LatLng(14.6460393, 120.9806892),
      LatLng(14.6460160, 120.9813920),
      LatLng(14.6459922, 120.9821107),
      LatLng(14.6459681, 120.9828340),
      LatLng(14.6457803, 120.9828286),
      LatLng(14.6457750, 120.9835551),
      LatLng(14.6457465, 120.9836214),
      LatLng(14.6473675, 120.9836492),
      LatLng(14.6473671, 120.9835978),
      LatLng(14.6473823, 120.9831526),
      LatLng(14.6473879, 120.9828893),
      LatLng(14.6474110, 120.9821788),
      LatLng(14.6474366, 120.9814395),
      LatLng(14.6474614, 120.9807396),
      LatLng(14.6474749, 120.9803452),
      LatLng(14.6474862, 120.9800277),
      LatLng(14.6475082, 120.9792933),
    ],
    fillColor: Color(0x33FFB74D),
    borderColor: Color(0xFFFFB74D),
  );

  static const BarangayCoverageArea area55 = BarangayCoverageArea(
    id: '55',
    name: 'Barangay 55',
    osmRelationId: 3400330,
    center: LatLng(14.6450598, 120.9812413),
    polygon: [
      LatLng(14.6446031, 120.9791998),
      LatLng(14.6445998, 120.9793015),
      LatLng(14.6445813, 120.9798659),
      LatLng(14.6445794, 120.9799236),
      LatLng(14.6445766, 120.9800085),
      LatLng(14.6445576, 120.9805888),
      LatLng(14.6445525, 120.9807455),
      LatLng(14.6445357, 120.9812604),
      LatLng(14.6445308, 120.9814089),
      LatLng(14.6445138, 120.9819272),
      LatLng(14.6445108, 120.9820191),
      LatLng(14.6445065, 120.9821510),
      LatLng(14.6445045, 120.9822131),
      LatLng(14.6444655, 120.9834041),
      LatLng(14.6444599, 120.9835764),
      LatLng(14.6457465, 120.9836214),
      LatLng(14.6457750, 120.9835551),
      LatLng(14.6457803, 120.9828286),
      LatLng(14.6459681, 120.9828340),
      LatLng(14.6459922, 120.9821107),
      LatLng(14.6460160, 120.9813920),
      LatLng(14.6460393, 120.9806892),
      LatLng(14.6460631, 120.9799779),
      LatLng(14.6460873, 120.9792466),
      LatLng(14.6453294, 120.9792235),
      LatLng(14.6446806, 120.9792022),
    ],
    fillColor: Color(0x33CE93D8),
    borderColor: Color(0xFFCE93D8),
  );

  static const BarangayCoverageArea area56 = BarangayCoverageArea(
    id: '56',
    name: 'Barangay 56',
    osmRelationId: 3400307,
    center: LatLng(14.6482187, 120.9768730),
    polygon: [
      LatLng(14.6488196, 120.9754842),
      LatLng(14.6476979, 120.9757019),
      LatLng(14.6475339, 120.9757352),
      LatLng(14.6475579, 120.9763261),
      LatLng(14.6475539, 120.9767465),
      LatLng(14.6475518, 120.9769225),
      LatLng(14.6475491, 120.9771847),
      LatLng(14.6475459, 120.9774894),
      LatLng(14.6475423, 120.9778525),
      LatLng(14.6475670, 120.9778533),
      LatLng(14.6479197, 120.9778642),
      LatLng(14.6482471, 120.9778743),
      LatLng(14.6485879, 120.9778848),
      LatLng(14.6489580, 120.9778963),
      LatLng(14.6489830, 120.9771591),
      LatLng(14.6489903, 120.9766830),
      LatLng(14.6489732, 120.9764772),
      LatLng(14.6489607, 120.9763272),
      LatLng(14.6489192, 120.9760249),
      LatLng(14.6489162, 120.9759736),
    ],
    fillColor: Color(0x3380CBC4),
    borderColor: Color(0xFF26A69A),
  );

  static const List<BarangayCoverageArea> allAreas = [
    area52,
    area53,
    area54,
    area55,
    area56,
  ];

  static BarangayCoverageArea areaFor(String? barangayId) {
    final id = normalizeBarangayId(barangayId);
    for (final area in allAreas) {
      if (area.id == id) return area;
    }
    return area52;
  }

  static LatLng centerFor(String? barangayId) => areaFor(barangayId).center;

  static String outsideCoverageLabel(String? barangayId) =>
      'Outside Barangay ${normalizeBarangayId(barangayId)} coverage';

  static bool contains(LatLng point, {String? barangayId}) {
    final ring = areaFor(barangayId).polygon;
    int crossings = 0;
    for (int i = 0; i < ring.length; i++) {
      final a = ring[i];
      final b = ring[(i + 1) % ring.length];
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
            for (final area in allAreas)
              Polygon(
                points: area.polygon,
                color: area.fillColor,
                borderColor: area.borderColor,
                borderStrokeWidth: 3,
              ),
          ],
        ),
        MarkerLayer(
          markers: [
            for (final area in allAreas)
              Marker(
                point: area.center,
                width: 108,
                height: 26,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xCC1B3A5C),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        area.name,
                        style: const TextStyle(
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
