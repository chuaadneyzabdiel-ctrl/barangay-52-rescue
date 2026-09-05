import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/barangay.dart';
import '../../providers/rescue_provider.dart';
import '../../widgets/home_barangay_picker.dart';

class CompleteProfileScreen extends StatefulWidget {
  final String uid;
  final String? initialName;
  final String? initialEmail;

  const CompleteProfileScreen({
    super.key,
    required this.uid,
    this.initialName,
    this.initialEmail,
  });

  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _addressController;
  final _emergencyNameController = TextEditingController();
  final _emergencyPhoneController = TextEditingController();
  String? _barangayId;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName ?? '');
    _phoneController = TextEditingController();
    _addressController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    _emergencyNameController.dispose();
    _emergencyPhoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading) return;
    if (!_formKey.currentState!.validate()) return;
    final email = (widget.initialEmail ?? '').trim();
    if (email.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Google account email is missing.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final provider = context.read<RescueProvider>();
      await provider.setCitizenProfileFromRegistered(
        uid: widget.uid,
        name: _nameController.text,
        email: email,
        phone: _phoneController.text,
        address: _addressController.text,
        emergencyContactName: _emergencyNameController.text.trim().isEmpty
            ? null
            : _emergencyNameController.text,
        emergencyContactPhone: _emergencyPhoneController.text.trim().isEmpty
            ? null
            : _emergencyPhoneController.text,
        barangayId: _barangayId,
      );
      await provider.persistSessionRole(UserRole.citizen);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not complete profile. Please try again.'),
          backgroundColor: Colors.orange,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        title: const Text('Complete profile'),
        backgroundColor: const Color(0xFF1B3A5C),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Full name'),
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? 'Full name is required.' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: widget.initialEmail ?? '',
                    readOnly: true,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration:
                        const InputDecoration(labelText: 'Mobile number'),
                    validator: (v) {
                      final value = (v ?? '').trim();
                      if (value.isEmpty) return 'Mobile number is required.';
                      if (value.length < 7) return 'Enter a valid mobile number.';
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _addressController,
                    maxLines: 2,
                    decoration:
                        const InputDecoration(labelText: 'Complete address'),
                    validator: (v) => (v ?? '').trim().isEmpty
                        ? 'Complete address is required.'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  HomeBarangayPicker(
                    value: _barangayId,
                    catalog: kBuiltInBarangays,
                    onChanged: (id) => setState(() => _barangayId = id),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _emergencyNameController,
                    decoration: const InputDecoration(
                      labelText: 'Emergency contact name (optional)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _emergencyPhoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Emergency contact number (optional)',
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save and continue'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
