import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/rescue_provider.dart';
import '../services/auth_service.dart';
import 'auth/auth_choice_screen.dart';
import 'citizen/sos_screen.dart';
import 'legal/terms_conditions_screen.dart';

/// Landing screen where the user selects their role.
/// In production, this would be replaced with proper authentication.
class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF1B3A5C).withValues(alpha: 0.5),
                      ),
                      child: const Icon(
                        Icons.health_and_safety,
                        size: 72,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'BARANGAY 52, CALOOCAN CITY',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Integrated Rescue Operations',
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 16,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Dispatch & Dynamic Relocation System',
                      style: TextStyle(
                        color: Colors.grey[500],
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 48),
                    _RoleCard(
                      icon: Icons.person,
                      title: 'Citizen',
                      subtitle: 'Send SOS emergency alerts',
                      color: Colors.red,
                      onTap: () async {
                        final provider = context.read<RescueProvider>();
                        provider.setRole(UserRole.citizen);

                        // Ensure we have a stored citizen name before opening the SOS screen.
                        await provider.loadCitizenProfile();
                        if (!context.mounted) return;

                        // Returning user: skip mode picker and open SOS directly.
                        final existingName = provider.citizenName;
                        final shouldAutoResumeRegistered =
                            provider.isCitizenRegistered &&
                                AuthService().currentUser != null;
                        if (existingName != null &&
                            existingName.trim().isNotEmpty &&
                            shouldAutoResumeRegistered) {
                          await provider.persistSessionRole(UserRole.citizen);
                          if (!context.mounted) return;
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SOSScreen(),
                            ),
                          );
                          return;
                        }

                        final selectedMode = await showModalBottomSheet<CitizenAccessMode>(
                          context: context,
                          backgroundColor: const Color(0xFF1B2838),
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                          ),
                          builder: (ctx) => SafeArea(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(height: 12),
                                const Text(
                                  'Choose citizen access mode',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                ListTile(
                                  leading: const Icon(Icons.verified_user, color: Colors.lightBlueAccent),
                                  title: const Text('Registered', style: TextStyle(color: Colors.white)),
                                  subtitle: const Text(
                                    'No cooldown, no daily cap, history tracking',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                  onTap: () => Navigator.pop(ctx, CitizenAccessMode.registered),
                                ),
                                ListTile(
                                  leading: const Icon(Icons.person_outline, color: Colors.orangeAccent),
                                  title: const Text('Guest', style: TextStyle(color: Colors.white)),
                                  subtitle: const Text(
                                    '60s cooldown, 3/day cap, strike system',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                  onTap: () => Navigator.pop(ctx, CitizenAccessMode.guest),
                                ),
                                const SizedBox(height: 8),
                              ],
                            ),
                          ),
                        );
                        if (selectedMode == null) return;
                        if (selectedMode == CitizenAccessMode.registered) {
                          final ok = await Navigator.of(context).push<bool>(
                            MaterialPageRoute<bool>(
                              builder: (_) => const AuthChoiceScreen(),
                            ),
                          );
                          if (ok != true || !context.mounted) return;
                          await provider.setCitizenAccessMode(
                            CitizenAccessMode.registered,
                            email: provider.citizenEmail,
                          );
                          if (!context.mounted) return;
                          await provider.persistSessionRole(UserRole.citizen);
                          if (!context.mounted) return;
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SOSScreen(),
                            ),
                          );
                          return;
                        }

                        await provider.setCitizenAccessMode(
                          CitizenAccessMode.guest,
                        );
                        String? name = provider.citizenName;

                        if (name == null || name.isEmpty) {
                          final controller = TextEditingController();
                          name = await showDialog<String>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Enter your name'),
                              content: TextField(
                                controller: controller,
                                decoration: const InputDecoration(
                                  labelText: 'Full name',
                                  hintText: 'e.g. Juan Dela Cruz',
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(ctx, controller.text.trim());
                                  },
                                  child: const Text('Continue'),
                                ),
                              ],
                            ),
                          );

                          if (name == null || name.isEmpty) {
                            return;
                          }

                          await provider.setCitizenProfile(name: name);
                        }

                        if (!context.mounted) return;
                        await provider.persistSessionRole(UserRole.citizen);
                        if (!context.mounted) return;
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SOSScreen(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton.filled(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const TermsConditionsScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.description_outlined, color: Colors.white),
                tooltip: 'Terms & Conditions',
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFF1B2838).withValues(alpha: 0.95),
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      child: Card(
        color: const Color(0xFF1B2838),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                            color: Colors.grey[500], fontSize: 13),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios,
                    color: Colors.grey[600], size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
