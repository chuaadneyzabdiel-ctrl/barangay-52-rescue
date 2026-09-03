import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/map_theme_provider.dart';

/// Uses global [MapThemeProvider] so basemap matches user choice from the layers sheet.
class RescueMapTileLayer extends StatelessWidget {
  const RescueMapTileLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MapThemeProvider>(
      builder: (context, theme, _) => theme.buildTileLayer(),
    );
  }
}
