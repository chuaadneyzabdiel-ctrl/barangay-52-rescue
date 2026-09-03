# Map tiles, caching, and data use

## What we use

- **OpenStreetMap** raster tiles (`tile.openstreetmap.org`) via `flutter_map`.
- **flutter_map_tile_caching (FMTC)** stores viewed tiles on the device (ObjectBox) so repeat pan/zoom uses **less mobile data** and works better on **slow or unstable networks**.

## Behavior

- **Cache-first browsing**: the app tries the local cache before downloading. Cached tiles are treated as valid for **14 days**, then refreshed when viewed again.
- **Cap**: about **15,000** browse-cached tiles per store (oldest removed when over limit) to limit storage.
- If FMTC fails to initialize (rare), maps fall back to the default **network-only** tile provider.

## Gestures

- Map rotation is **disabled** (pinch zoom and pan only) for smoother use on phones.

## License note

`flutter_map_tile_caching` is **GPL-3.0**. If you distribute the app, ensure your licensing complies with GPL requirements for that component (or replace FMTC with another caching approach).

## OSM tile usage policy

Heavy production use of `tile.openstreetmap.org` may hit fair-use limits. For large deployments, consider a **commercial tile CDN** or **self-hosted** tile server and point `kRescueOsmTileUrlTemplate` in `lib/map/rescue_map_tiles.dart` to that URL.
