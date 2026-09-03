import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/rescue_provider.dart';
import '../../services/auth_service.dart';
import 'complete_profile_screen.dart';
import 'login_screen.dart';
import 'signup_screen.dart';

class AuthChoiceScreen extends StatelessWidget {
  const AuthChoiceScreen({super.key});

  Future<void> _continueWithGoogle(BuildContext context) async {
    try {
      final auth = AuthService();
      final cred = await auth.signInWithGoogle();
      final user = cred.user;
      if (user == null) {
        throw Exception('No user from Google sign-in');
      }
      final provider = context.read<RescueProvider>();
      final loaded = await provider.loadRegisteredCitizenProfile(
        user.uid,
        fallbackEmail: user.email,
      );
      if (loaded) {
        if (context.mounted) Navigator.of(context).pop(true);
        return;
      }
      if (!context.mounted) return;
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => CompleteProfileScreen(
            uid: user.uid,
            initialName: user.displayName,
            initialEmail: user.email,
          ),
        ),
      );
      if (ok == true && context.mounted) {
        Navigator.of(context).pop(true);
      }
    } on FirebaseAuthException catch (e) {
      if (!context.mounted) return;
      String msg;
      switch (e.code) {
        case 'popup-closed-by-user':
          msg = 'Google sign-in was cancelled.';
          break;
        case 'account-exists-with-different-credential':
          msg = 'This email is linked to another sign-in method.';
          break;
        case 'network-request-failed':
          msg = 'No internet connection. Please try again.';
          break;
        case 'operation-not-allowed':
          msg = 'Google sign-in is not enabled in Firebase.';
          break;
        default:
          msg = e.message ?? 'Google sign-in failed.';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: Colors.orange.shade800,
        ),
      );
    } on Exception {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Google sign-in failed.'),
          backgroundColor: Colors.orange.shade800,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        title: const Text('Registered Access'),
        backgroundColor: const Color(0xFF1B3A5C),
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Continue as a registered citizen',
                  style: TextStyle(
                    color: Colors.grey[200],
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Log in to your account or create a new one.',
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _continueWithGoogle(context),
                    icon: const Icon(Icons.account_circle),
                    label: const Text('Continue with Google'),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final ok = await Navigator.of(context).push<bool>(
                        MaterialPageRoute<bool>(
                          builder: (_) => const LoginScreen(),
                        ),
                      );
                      if (ok == true && context.mounted) {
                        Navigator.of(context).pop(true);
                      }
                    },
                    icon: const Icon(Icons.login),
                    label: const Text('Log in'),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final ok = await Navigator.of(context).push<bool>(
                        MaterialPageRoute<bool>(
                          builder: (_) => const SignupScreen(),
                        ),
                      );
                      if (ok == true && context.mounted) {
                        Navigator.of(context).pop(true);
                      }
                    },
                    icon: const Icon(Icons.person_add),
                    label: const Text('Create account'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
