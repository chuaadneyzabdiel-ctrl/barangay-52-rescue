import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';

/// OpenStreetMap raster tiles (same URL across the app).
/// Tiles are cached on device via flutter_map_tile_caching (FMTC) to reduce
/// mobile data use and improve pan/zoom on weak networks (e.g. Philippines).
///
/// FMTC is GPL-3.0 — see package license if you distribute the app.
const String kRescueOsmTileUrlTemplate =
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

const String kRescueMapUserAgentPackageName = 'com.caloocan.rescue';

const String _fmtcStoreName = 'caloocan_rescue_osm';

/// Initialize FMTC ObjectBox backend and ensure the OSM browse cache store exists.
/// Safe to call once at startup; failures fall back to [NetworkTileProvider].
Future<void> initRescueMapTiles() async {
  try {
    await FMTCObjectBoxBackend().initialise();
    const store = FMTCStore(_fmtcStoreName);
    if (!await store.manage.ready) {
      await store.manage.create();
    }
    RescueMapTiles._ready = true;
    if (kDebugMode) {
      debugPrint('RescueMapTiles: FMTC cache ready (store $_fmtcStoreName)');
    }
  } catch (e, st) {
    RescueMapTiles._ready = false;
    debugPrint('RescueMapTiles: FMTC init failed, using network tiles only: $e');
    debugPrint('$st');
  }
}

/// Smoother phone gestures with rotation enabled for heading-up navigation.
const InteractionOptions kRescueMapInteractions = InteractionOptions(
  flags: InteractiveFlag.all,
);

/// Raster basemap options (OpenStreetMap ecosystem + Esri imagery).
/// Not the Google Maps SDK — POI density differs by provider.
enum RescueMapStyle {
  /// OSM Standard
  standard,

  /// Carto Positron-style light base
  cartoLight,

  /// Carto dark base
  dark,

  /// Esri World Imagery (satellite-style; separate attribution requirements)
  satellite,

  /// OpenTopoMap (terrain / hillshade)
  terrain,
}

class RescueMapTiles {
  RescueMapTiles._();

  static bool _ready = false;

  static bool get isFmtcReady => _ready;

  static TileProvider? _cachedProvider;

  /// Prefer disk cache first (weak signal / less data), refresh after [staleDays].
  static TileProvider get tileProvider {
    if (!_ready) {
      return NetworkTileProvider();
    }
    _cachedProvider ??= const FMTCStore(_fmtcStoreName).getTileProvider(
      settings: FMTCTileProviderSettings(
        behavior: CacheBehavior.cacheFirst,
        cachedValidDuration: const Duration(days: 14),
        maxStoreLength: 15000,
        fallbackToAlternativeStore: false,
        setInstance: false,
      ),
    );
    return _cachedProvider!;
  }

  static String _urlTemplateForStyle(RescueMapStyle style) {
    switch (style) {
      case RescueMapStyle.standard:
        return kRescueOsmTileUrlTemplate;
      case RescueMapStyle.cartoLight:
        return 'https://cartodb-basemaps-a.global.ssl.fastly.net/light_all/{z}/{x}/{y}.png';
      case RescueMapStyle.dark:
        return 'https://cartodb-basemaps-a.global.ssl.fastly.net/dark_all/{z}/{x}/{y}.png';
      case RescueMapStyle.satellite:
        // Esri tiles use z/y/x order.
        return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
      case RescueMapStyle.terrain:
        return 'https://tile.opentopomap.org/{z}/{x}/{y}.png';
    }
  }

  /// Tile layer for a chosen basemap (cached when FMTC is ready).
  /// [ValueKey] forces a fresh tile layer when the style changes (fixes mobile
  /// basemap not updating when switching Default / Satellite / etc.).
  static TileLayer tileLayerForStyle(RescueMapStyle style) {
    return TileLayer(
      key: ValueKey<RescueMapStyle>(style),
      urlTemplate: _urlTemplateForStyle(style),
      userAgentPackageName: kRescueMapUserAgentPackageName,
      maxNativeZoom: 19,
      tileProvider: tileProvider,
    );
  }

  /// Standard OSM tile layer for all [FlutterMap] screens.
  static TileLayer osmTileLayer() => tileLayerForStyle(RescueMapStyle.standard);
}
