import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'map/rescue_map_tiles.dart';
import 'providers/map_theme_provider.dart';
import 'providers/rescue_provider.dart';
import 'screens/session_bootstrap_screen.dart';
import 'services/local_notification_service.dart';
import 'widgets/connectivity_banner.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e, st) {
    debugPrint('Firebase.initializeApp failed: $e');
    debugPrint('$st');
  }

  await initRescueMapTiles();
  await LocalNotificationService().init();

  runApp(const RescueApp());
}

class RescueApp extends StatelessWidget {
  const RescueApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => RescueProvider()),
        ChangeNotifierProvider(create: (_) => MapThemeProvider()),
      ],
      child: MaterialApp(
        title: 'Caloocan Rescue',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF1B3A5C),
          brightness: Brightness.light,
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF1B3A5C),
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        themeMode: ThemeMode.dark,
        builder: (context, child) => ConnectivityBanner(child: child!),
        home: const SessionBootstrapScreen(),
      ),
    );
  }
}
