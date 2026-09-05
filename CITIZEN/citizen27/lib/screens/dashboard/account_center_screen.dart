import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/response_unit_status.dart';
import '../../providers/rescue_provider.dart';
import '../../services/auth_service.dart';
import '../legal/terms_conditions_screen.dart';
import '../session_bootstrap_screen.dart';

class AccountCenterScreen extends StatelessWidget {
  const AccountCenterScreen({super.key});

  static Future<void> _exitToBootstrap(BuildContext context) async {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const SessionBootstrapScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<RescueProvider>();
    final isCitizen = provider.currentRole == UserRole.citizen;
    final isResponder = provider.currentRole == UserRole.responder;
    final isLgu = provider.currentRole == UserRole.lguAdmin;
    final totalHistory = provider.sosHistory.length;
    final completed = provider.sosHistory.where((e) => e.status.name == 'completed').length;
    final cancelled = provider.sosHistory.where((e) => e.status.name == 'cancelled').length;
    final users = _buildLguUserRows(provider);
    final citizenRows = users.where((u) => u['role'] == 'citizen').toList();
    final registeredCitizenRows =
        citizenRows.where((u) => u['isGuest'] != true).toList();
    final guestCitizenRows = citizenRows.where((u) => u['isGuest'] == true).toList();
    final responderRows = users.where((u) => u['role'] == 'responder').toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B3A5C),
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Account Center'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (isLgu) ...[
            _lguSectionHeader(
              icon: Icons.verified_user_outlined,
              title: 'Registered citizen accounts',
              subtitle: '${registeredCitizenRows.length} accounts',
            ),
            _buildLguCitizenSection(
              context: context,
              rows: registeredCitizenRows,
              emptyText: 'No registered citizen accounts yet.',
            ),
            const SizedBox(height: 12),
            const Divider(color: Colors.white24, height: 28),
            _lguSectionHeader(
              icon: Icons.person_outline,
              title: 'Guest citizen accounts',
              subtitle: '${guestCitizenRows.length} accounts',
            ),
            _buildLguCitizenSection(
              context: context,
              rows: guestCitizenRows,
              emptyText: 'No guest accounts yet.',
            ),
            const SizedBox(height: 12),
            const Divider(color: Colors.white24, height: 32),
            _lguSectionHeader(
              icon: Icons.local_shipping_outlined,
              title: 'Response Units',
              subtitle: '${responderRows.length} units',
            ),
            _buildLguUserSection(
              context: context,
              rows: responderRows,
              emptyText: 'No response units yet.',
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () async {
                await context.read<RescueProvider>().lguLogout();
                if (context.mounted) await _exitToBootstrap(context);
              },
              icon: const Icon(Icons.logout, color: Colors.orangeAccent),
              label: const Text(
                'Log out (LGU session)',
                style: TextStyle(color: Colors.orangeAccent),
              ),
            ),
            const SizedBox(height: 12),
          ],
          _card(
            title: 'Current Role',
            icon: Icons.badge,
            lines: [
              switch (provider.currentRole) {
                UserRole.citizen => 'Citizen',
                UserRole.responder => 'Responder',
                UserRole.lguAdmin => 'LGU Admin',
              }
            ],
          ),
          if (isCitizen) ...[
            const SizedBox(height: 12),
            _card(
              title: 'Citizen Account',
              icon: Icons.person,
              lines: [
                'Mode: ${provider.isCitizenRegistered ? 'REGISTERED' : 'GUEST'}',
                'Name: ${provider.citizenName ?? 'Not set'}',
                'Citizen ID: ${provider.citizenId ?? 'Not set'}',
                if (provider.isCitizenRegistered)
                  'Email: ${provider.citizenEmail?.trim().isNotEmpty == true ? provider.citizenEmail : 'Not set'}',
                if (provider.isCitizenRegistered)
                  'Phone: ${provider.citizenPhone?.trim().isNotEmpty == true ? provider.citizenPhone : 'Not set'}',
                if (provider.isCitizenRegistered)
                  'Address: ${provider.citizenAddress?.trim().isNotEmpty == true ? provider.citizenAddress : 'Not set'}',
                if (provider.isCitizenBannedByLguFromCache(provider.citizenId)) ...[
                  'LGU suspension: ACTIVE',
                  if (provider.citizenLguBanReasonFromCache(provider.citizenId) != null)
                    'Reason: ${provider.citizenLguBanReasonFromCache(provider.citizenId)}',
                ],
              ],
            ),
            const SizedBox(height: 12),
            _card(
              title: 'SOS Access Controls',
              icon: Icons.shield,
              lines: [
                if (provider.isCitizenRegistered) ...[
                  'No daily cap',
                  'No cooldown',
                  'SOS history tracking enabled',
                ] else ...[
                  'Cooldown: 60 seconds',
                  'Daily cap: ${provider.guestSosCountToday}/3',
                  'Strikes: ${provider.guestStrikes}/3',
                  'Banned: ${provider.guestIsBanned ? 'YES' : 'NO'}',
                  'Guest limits persist on this device',
                ],
              ],
            ),
            const SizedBox(height: 12),
            if (provider.isCitizenGuest)
              FilledButton.tonalIcon(
                onPressed: () async {
                  await context.read<RescueProvider>().citizenLogout();
                  if (context.mounted) await _exitToBootstrap(context);
                },
                icon: const Icon(Icons.logout),
                label: const Text('Exit guest session'),
              )
            else
              FilledButton.tonalIcon(
                onPressed: () async {
                  await AuthService().signOut();
                  await context.read<RescueProvider>().citizenLogout();
                  if (context.mounted) await _exitToBootstrap(context);
                },
                icon: const Icon(Icons.logout),
                label: const Text('Log out (Registered session)'),
              ),
          ],
          if (isResponder && provider.currentResponderUnit != null) ...[
            const SizedBox(height: 12),
            _card(
              title: 'Responder session',
              icon: Icons.local_shipping,
              lines: [
                'Unit: ${provider.currentResponderUnit!.callSign}',
                'ID: ${provider.currentResponderUnit!.id}',
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () async {
                final id = provider.currentResponderUnit!.id;
                await context.read<RescueProvider>().responderLogout(id);
                if (context.mounted) await _exitToBootstrap(context);
              },
              icon: const Icon(Icons.logout),
              label: const Text('Log out (Responder session)'),
            ),
          ],
          const SizedBox(height: 12),
          _card(
            title: 'Incident Stats',
            icon: Icons.analytics,
            lines: [
              'Active SOS: ${provider.activeSosRequests.length}',
              'SOS history total: $totalHistory',
              'Completed: $completed',
              'Cancelled: $cancelled',
            ],
          ),
          const SizedBox(height: 12),
          _card(
            title: 'Security Notes',
            icon: Icons.security,
            lines: const [
              'Use Firebase rules with least privilege.',
              'Use App Check and server-side validation.',
              'Avoid direct client writes to sensitive nodes.',
            ],
          ),
          const SizedBox(height: 12),
          Card(
            color: const Color(0xFF1B3A5C).withValues(alpha: 0.6),
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: ListTile(
              leading: const Icon(Icons.gavel, color: Colors.white70),
              title: const Text(
                'Terms & Conditions',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: const Text(
                'Read usage rules and legal notices',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right, color: Colors.white54),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TermsConditionsScreen(),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _lguSectionHeader({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Map<String, Object?>> _buildLguUserRows(RescueProvider provider) {
    final now = DateTime.now();
    final merged = <String, Map<String, Object?>>{};

    for (final raw in provider.accountUsers) {
      final id = (raw['id']?.toString() ?? '').trim();
      if (id.isEmpty) continue;
      final role = (raw['role']?.toString() ?? 'citizen').trim();
      final createdAt = (raw['createdAt'] as num?)?.toInt() ?? 0;
      final updatedAt = (raw['updatedAt'] as num?)?.toInt() ?? 0;
      final created = createdAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(createdAt)
          : DateTime.fromMillisecondsSinceEpoch(updatedAt > 0 ? updatedAt : 0);
      merged[id] = {
        'id': id,
        'role': role,
        'name': (raw['name']?.toString() ?? id),
        'email': raw['email']?.toString(),
        'isGuest': raw['isGuest'] == true,
        'approvedByLgu': raw['approvedByLgu'] == true,
        'responseUnitStatus': raw['responseUnitStatus']?.toString(),
        'bannedByLgu': raw['bannedByLgu'] == true,
        'banReason': raw['banReason']?.toString(),
        'createdAt': created,
        'isNew': createdAt > 0 && now.difference(created).inHours <= 24,
      };
    }

    for (final unit in provider.unitsForDisplay) {
      merged.putIfAbsent(unit.id, () {
        return {
          'id': unit.id,
          'role': 'responder',
          'name': unit.callSign,
          'email': null,
          'isGuest': false,
          'approvedByLgu': false,
          'responseUnitStatus': null,
          'createdAt': DateTime.fromMillisecondsSinceEpoch(0),
          'isNew': false,
        };
      });
    }

    for (final sos in [...provider.activeSosRequests, ...provider.sosHistory]) {
      final id = sos.citizenId.trim();
      if (id.isEmpty) continue;
      merged.putIfAbsent(id, () {
        return {
          'id': id,
          'role': 'citizen',
          'name': sos.citizenName,
          'email': null,
          'isGuest': id.startsWith('guest-'),
          'approvedByLgu': null,
          'bannedByLgu': false,
          'banReason': null,
          'createdAt': sos.createdAt,
          'isNew': now.difference(sos.createdAt).inHours <= 24,
        };
      });
    }

    final rows = merged.values.toList();
    rows.sort((a, b) {
      final ad = a['createdAt'] is DateTime ? a['createdAt'] as DateTime : DateTime.fromMillisecondsSinceEpoch(0);
      final bd = b['createdAt'] is DateTime ? b['createdAt'] as DateTime : DateTime.fromMillisecondsSinceEpoch(0);
      return bd.compareTo(ad);
    });
    return rows;
  }

  Widget _buildLguCitizenSection({
    required BuildContext context,
    required List<Map<String, Object?>> rows,
    required String emptyText,
  }) {
    if (rows.isEmpty) {
      return Card(
        color: const Color(0xFF1B3A5C).withValues(alpha: 0.45),
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(
            emptyText,
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ),
      );
    }
    return Card(
      color: const Color(0xFF1B3A5C).withValues(alpha: 0.45),
      elevation: 2,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: ExpansionTile(
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
        iconColor: Colors.white70,
        collapsedIconColor: Colors.white54,
        title: Text(
          'Tap to expand',
          style: TextStyle(color: Colors.grey[500], fontSize: 12),
        ),
        children: [
          ...rows.take(80).map((u) => _lguCitizenRowCard(context, u)),
        ],
      ),
    );
  }

  Widget _lguCitizenRowCard(BuildContext context, Map<String, Object?> u) {
    final name = u['name']?.toString() ?? 'Unknown';
    final id = u['id']?.toString() ?? '';
    final email = u['email']?.toString();
    final isNew = u['isNew'] == true;
    final banned = u['bannedByLgu'] == true;
    final banReason = u['banReason']?.toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: banned ? Colors.red.withValues(alpha: 0.45) : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              if (isNew)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'NEW',
                    style: TextStyle(color: Colors.greenAccent, fontSize: 10),
                  ),
                ),
              if (banned)
                Container(
                  margin: const EdgeInsets.only(left: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'BANNED',
                    style: TextStyle(color: Colors.redAccent, fontSize: 10),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 3),
          if (email != null && email.trim().isNotEmpty)
            Text(email, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text(id, style: const TextStyle(color: Colors.white54, fontSize: 11)),
          if (banned && banReason != null && banReason.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Ban reason: $banReason',
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              if (!banned)
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                  ),
                  onPressed: () => _promptBanCitizen(context, id, name),
                  child: const Text('Ban'),
                )
              else
                OutlinedButton(
                  onPressed: () => _promptUnbanCitizen(context, id, name),
                  child: const Text('Unban'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _promptBanCitizen(BuildContext context, String id, String displayName) async {
    final controller = TextEditingController();
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Ban $displayName'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Provide a reason. This is stored with the account and may be shown in the citizen app when SOS is blocked.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    labelText: 'Reason for ban',
                    alignLabelWithHint: true,
                  ),
                  maxLines: 4,
                  autofocus: true,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm ban'),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
      final reason = controller.text.trim();
      if (reason.length < 3) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Reason must be at least 3 characters.'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      await context.read<RescueProvider>().setCitizenBanByLgu(
            citizenId: id,
            banned: true,
            reason: reason,
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$displayName banned.'), backgroundColor: Colors.red.shade800),
        );
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _promptUnbanCitizen(BuildContext context, String id, String displayName) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unban account'),
        content: Text('Remove suspension for $displayName?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unban'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await context.read<RescueProvider>().setCitizenBanByLgu(citizenId: id, banned: false);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$displayName unbanned.'), backgroundColor: Colors.green),
      );
    }
  }

  Widget _buildLguUserSection({
    required BuildContext context,
    required List<Map<String, Object?>> rows,
    required String emptyText,
  }) {
    if (rows.isEmpty) {
      return Card(
        color: const Color(0xFF1B3A5C).withValues(alpha: 0.45),
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(
            emptyText,
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ),
      );
    }
    return Card(
      color: const Color(0xFF1B3A5C).withValues(alpha: 0.45),
      elevation: 2,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: ExpansionTile(
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
        iconColor: Colors.white70,
        collapsedIconColor: Colors.white54,
        title: Text(
          'Tap to expand',
          style: TextStyle(color: Colors.grey[500], fontSize: 12),
        ),
        children: [
          ...rows.take(80).map((u) {
            final name = u['name']?.toString() ?? 'Unknown';
            final id = u['id']?.toString() ?? '';
            final role = u['role']?.toString() ?? '';
            final email = u['email']?.toString();
            final isGuest = u['isGuest'] == true;
            final isNew = u['isNew'] == true;
            final isResponder = role == 'responder';
            final unitStatus = responseUnitStatusFromUser(u);
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (isNew)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.green.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'NEW',
                            style: TextStyle(color: Colors.greenAccent, fontSize: 10),
                          ),
                        ),
                      if (isResponder) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: _responseUnitStatusColor(unitStatus).withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            unitStatus.label.toUpperCase(),
                            style: TextStyle(
                              color: _responseUnitStatusColor(unitStatus),
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$role${isGuest ? ' • guest' : ''}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  if (email != null && email.trim().isNotEmpty)
                    Text(
                      email,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  Text(
                    id,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  if (isResponder) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<ResponseUnitStatus>(
                      value: unitStatus,
                      dropdownColor: const Color(0xFF1B3A5C),
                      decoration: const InputDecoration(
                        labelText: 'Status',
                        isDense: true,
                      ),
                      items: [
                        for (final s in ResponseUnitStatus.values)
                          DropdownMenuItem(
                            value: s,
                            child: Text(s.label),
                          ),
                      ],
                      onChanged: (next) {
                        if (next == null) return;
                        _setResponseUnitStatus(context, id, next, name: name);
                      },
                    ),
                  ],
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Color _responseUnitStatusColor(ResponseUnitStatus status) {
    switch (status) {
      case ResponseUnitStatus.inService:
        return Colors.greenAccent;
      case ResponseUnitStatus.outOfService:
        return Colors.orangeAccent;
      case ResponseUnitStatus.underMaintenance:
        return Colors.amberAccent;
      case ResponseUnitStatus.disabled:
        return Colors.redAccent;
    }
  }

  Future<void> _setResponseUnitStatus(
    BuildContext context,
    String responderId,
    ResponseUnitStatus status, {
    String? name,
  }) async {
    try {
      await context.read<RescueProvider>().setResponseUnitStatus(
            responderId: responderId,
            status: status,
            name: name,
          );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
        );
      }
    }
  }

  Widget _card({

    required String title,

    required IconData icon,

    required List<String> lines,

  }) {

    return Card(

      color: const Color(0xFF1B3A5C).withValues(alpha: 0.6),

      elevation: 4,

      shape: RoundedRectangleBorder(

        borderRadius: BorderRadius.circular(16),

        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),

      ),

      child: Padding(

        padding: const EdgeInsets.all(16),

        child: Row(

          crossAxisAlignment: CrossAxisAlignment.start,

          children: [

            Container(

              padding: const EdgeInsets.all(10),

              decoration: BoxDecoration(

                color: Colors.white.withValues(alpha: 0.1),

                borderRadius: BorderRadius.circular(10),

              ),

              child: Icon(icon, color: Colors.white70, size: 22),

            ),

            const SizedBox(width: 12),

            Expanded(

              child: Column(

                crossAxisAlignment: CrossAxisAlignment.start,

                children: [

                  Text(

                    title,

                    style: const TextStyle(

                      color: Colors.white,

                      fontSize: 16,

                      fontWeight: FontWeight.bold,

                    ),

                  ),

                  const SizedBox(height: 8),

                  ...lines.map(

                    (line) => Padding(

                      padding: const EdgeInsets.only(bottom: 4),

                      child: Text(

                        line,

                        style: TextStyle(

                          color: Colors.white.withValues(alpha: 0.85),

                          fontSize: 13,

                        ),

                      ),

                    ),

                  ),

                ],

              ),

            ),

          ],

        ),

      ),

    );

  }

}

