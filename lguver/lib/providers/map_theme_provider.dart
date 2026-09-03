import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';

import '../map/rescue_map_tiles.dart';

/// Global map appearance + optional overlays (traffic on route is navigation-only).
class MapThemeProvider extends ChangeNotifier {
  RescueMapStyle _style = RescueMapStyle.standard;

  /// Colored traffic segments on responder navigation (mock traffic from OSRM geometry).
  bool showRouteTrafficOverlay = true;

  RescueMapStyle get style => _style;

  void setStyle(RescueMapStyle value) {
    if (value == _style) return;
    _style = value;
    notifyListeners();
  }

  void setRouteTrafficOverlay(bool value) {
    if (value == showRouteTrafficOverlay) return;
    showRouteTrafficOverlay = value;
    notifyListeners();
  }

  /// Tile layer for all [FlutterMap] screens.
  TileLayer buildTileLayer() => RescueMapTiles.tileLayerForStyle(_style);
}
