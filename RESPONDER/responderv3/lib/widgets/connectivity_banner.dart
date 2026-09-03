import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

/// Shows a banner when the device has no connectivity (offline) or when
/// the app can't reliably reach Firebase (unstable/connecting).
class ConnectivityBanner extends StatefulWidget {
  final Widget child;

  const ConnectivityBanner({super.key, required this.child});

  @override
  State<ConnectivityBanner> createState() => _ConnectivityBannerState();
}

class _ConnectivityBannerState extends State<ConnectivityBanner> {
  bool _isOffline = false;
  bool _firebaseDisconnected = false;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  StreamSubscription<DatabaseEvent>? _firebaseSub;

  @override
  void initState() {
    super.initState();
    _sub = Connectivity().onConnectivityChanged.listen(_update);
    Connectivity().checkConnectivity().then(_update);
    _firebaseSub =
        FirebaseDatabase.instance.ref('.info/connected').onValue.listen((event) {
      final connected = event.snapshot.value == true;
      final disconnected = !connected;
      if (mounted && _firebaseDisconnected != disconnected) {
        setState(() => _firebaseDisconnected = disconnected);
      }
    });
  }

  void _update(List<ConnectivityResult> result) {
    final offline = result.isEmpty ||
        result.every((r) => r == ConnectivityResult.none);
    if (mounted && _isOffline != offline) {
      setState(() => _isOffline = offline);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _firebaseSub?.cancel();
    super.dispose();
  }

  Widget _banner({
    required Color color,
    required IconData icon,
    required String text,
  }) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        color: color,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showUnstable = !_isOffline && _firebaseDisconnected;
    return Stack(
      children: [
        widget.child,
        if (_isOffline)
          _banner(
            color: Colors.orange.shade800,
            icon: Icons.cloud_off,
            text: 'No connection. Updates will sync when back online.',
          )
        else if (showUnstable)
          _banner(
            color: Colors.amber.shade800,
            icon: Icons.wifi_tethering_error_rounded,
            text: 'Weak/unstable connection. Live updates may be delayed.',
          ),
      ],
    );
  }
}
