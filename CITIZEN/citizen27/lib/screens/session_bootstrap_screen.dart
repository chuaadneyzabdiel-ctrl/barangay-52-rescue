import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/rescue_provider.dart';
import '../services/auth_service.dart';
import 'citizen/sos_screen.dart';
import 'role_selection_screen.dart';

/// Restores last role (citizen / responder / LGU) from local storage.
class SessionBootstrapScreen extends StatefulWidget {
  const SessionBootstrapScreen({super.key});

  @override
  State<SessionBootstrapScreen> createState() => _SessionBootstrapScreenState();
}

class _SessionBootstrapScreenState extends State<SessionBootstrapScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _route());
  }

  bool _hasLocalCitizenProfile(RescueProvider provider) {
    final name = provider.citizenName?.trim() ?? '';
    final id = provider.citizenId?.trim() ?? '';
    return name.isNotEmpty && id.isNotEmpty;
  }

  Future<void> _route() async {
    final provider = context.read<RescueProvider>();
    await provider.loadCitizenProfile();
    final role = await provider.readPersistedRole();
    if (!mounted) return;

    if (role == null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const RoleSelectionScreen()),
      );
      return;
    }

    provider.setRole(role);

    switch (role) {
      case UserRole.citizen:
        if (provider.isCitizenRegistered) {
          final authUser = await AuthService().waitForRestoredUser();
          if (!mounted) return;
          var loaded = false;
          if (authUser != null) {
            try {
              loaded = await provider.loadRegisteredCitizenProfile(
                authUser.uid,
                fallbackEmail: authUser.email,
              );
            } catch (_) {
              loaded = false;
            }
          }
          if (!mounted) return;
          if (loaded || _hasLocalCitizenProfile(provider)) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(builder: (_) => const SOSScreen()),
            );
            return;
          }
          await provider.clearPersistedSessionKeys();
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(builder: (_) => const RoleSelectionScreen()),
          );
          return;
        }

        final name = provider.citizenName;
        if (name != null && name.trim().isNotEmpty) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(builder: (_) => const SOSScreen()),
          );
        } else {
          await provider.clearPersistedSessionKeys();
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(builder: (_) => const RoleSelectionScreen()),
          );
        }
        break;
      case UserRole.responder:
        await provider.clearPersistedSessionKeys();
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const RoleSelectionScreen()),
        );
        break;
      case UserRole.lguAdmin:
        await provider.clearPersistedSessionKeys();
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const RoleSelectionScreen()),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0D1B2A),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white70),
            SizedBox(height: 16),
            Text(
              'Loading session…',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
