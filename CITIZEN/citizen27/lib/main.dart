import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'map/rescue_map_tiles.dart';
import 'providers/map_theme_provider.dart';
import 'providers/rescue_provider.dart';
import 'screens/session_bootstrap_screen.dart';
import 'services/local_notification_service.dart';
import 'widgets/connectivity_banner.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initRescueMapTiles();
  await LocalNotificationService().init();

  if (kIsWeb) {
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'AIzaSyCk5W6uTGYRP5xZxy4KDk1exSboQLpLN4E',
        authDomain: 'rescue-app-c79cf.firebaseapp.com',
        databaseURL: 'https://rescue-app-c79cf-default-rtdb.asia-southeast1.firebasedatabase.app',
        projectId: 'rescue-app-c79cf',
        storageBucket: 'rescue-app-c79cf.firebasestorage.app',
        messagingSenderId: '727417603023',
        appId: '1:727417603023:web:e5bfd8e01ea6a9706508ba',
        measurementId: 'G-YKNNEVKM86',
      ),
    );
  } else {
    await Firebase.initializeApp();
  }

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
        title: 'Caloocan City Integrated Rescue Operations',
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
