import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../map/rescue_map_tiles.dart';
import '../providers/map_theme_provider.dart';

/// Google-Maps-style "Map type" + "Map details" bottom sheet (raster tiles only).
Future<void> showMapLayersSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1E1E1E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return Consumer<MapThemeProvider>(
        builder: (context, theme, _) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewPadding.bottom + 16,
              left: 16,
              right: 16,
              top: 12,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Map',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close, color: Colors.white70),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Map type',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      _styleChip(
                        context,
                        label: 'Default',
                        selected: theme.style == RescueMapStyle.standard,
                        onTap: () =>
                            theme.setStyle(RescueMapStyle.standard),
                      ),
                      _styleChip(
                        context,
                        label: 'Light',
                        selected: theme.style == RescueMapStyle.cartoLight,
                        onTap: () =>
                            theme.setStyle(RescueMapStyle.cartoLight),
                      ),
                      _styleChip(
                        context,
                        label: 'Dark',
                        selected: theme.style == RescueMapStyle.dark,
                        onTap: () => theme.setStyle(RescueMapStyle.dark),
                      ),
                      _styleChip(
                        context,
                        label: 'Satellite',
                        selected: theme.style == RescueMapStyle.satellite,
                        onTap: () =>
                            theme.setStyle(RescueMapStyle.satellite),
                      ),
                      _styleChip(
                        context,
                        label: 'Terrain',
                        selected: theme.style == RescueMapStyle.terrain,
                        onTap: () => theme.setStyle(RescueMapStyle.terrain),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 28, color: Colors.white24),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Map details',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  value: theme.showRouteTrafficOverlay,
                  onChanged: theme.setRouteTrafficOverlay,
                  activeThumbColor: Colors.lightBlueAccent,
                  title: const Text(
                    'Traffic on route (responder nav)',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  subtitle: const Text(
                    'Colors route by simulated congestion (not live road data).',
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Basemaps use OpenStreetMap, Carto, OpenTopoMap, or Esri imagery. '
                  'They differ from Google Maps POI coverage. Live traffic ETA requires a paid traffic API.',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

Widget _styleChip(
  BuildContext context, {
  required String label,
  required bool selected,
  required VoidCallback onTap,
}) {
  return Padding(
    padding: const EdgeInsets.only(right: 8),
    child: Material(
      color: selected ? Colors.blue.shade900.withValues(alpha: 0.5) : Colors.white12,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? Colors.lightBlueAccent : Colors.transparent,
              width: 2,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white70,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              fontSize: 13,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Compact FAB-style control to open the map sheet.
class MapLayersMapButton extends StatelessWidget {
  const MapLayersMapButton({super.key, this.mini = true});

  final bool mini;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1B3A5C),
      elevation: 4,
      shadowColor: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => showMapLayersSheet(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(
            mini ? Icons.layers_outlined : Icons.map_outlined,
            color: Colors.white,
            size: mini ? 24 : 28,
          ),
        ),
      ),
    );
  }
}
