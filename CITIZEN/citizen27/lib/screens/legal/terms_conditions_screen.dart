import 'package:flutter/material.dart';

class TermsConditionsScreen extends StatelessWidget {
  const TermsConditionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B3A5C),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Terms & Conditions'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'Terms & Conditions',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Last Updated: March 2026',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            SizedBox(height: 20),
            _TermsSection(
              number: '1',
              title: 'Purpose of Service',
              body:
                  'This application is intended for emergency assistance requests and emergency response coordination only.',
            ),
            _TermsSection(
              number: '2',
              title: 'Emergency Use Only',
              body:
                  'Users must submit SOS requests only for real and urgent incidents. Non-emergency use is prohibited.',
            ),
            _TermsSection(
              number: '3',
              title: 'Accuracy of Information',
              body:
                  'Users are responsible for providing truthful and accurate incident details. Inaccurate location/details may delay response.',
            ),
            _TermsSection(
              number: '4',
              title: 'False Alarms and Misuse',
              body:
                  'Intentionally submitting false alerts, prank requests, or repeated misuse may result in account restrictions or suspension, and may be referred to proper authorities when applicable.',
            ),
            _TermsSection(
              number: '5',
              title: 'Location and Tracking Consent',
              body:
                  'By using SOS features, users consent to GPS/location collection and sharing with authorized responders and dispatch personnel for incident handling and navigation.',
            ),
            _TermsSection(
              number: '6',
              title: 'Data Handling and Privacy',
              body:
                  'The system processes only operationally relevant data (e.g., SOS details, location, timestamps, response status) to support emergency operations, monitoring, and service improvement.',
            ),
            _TermsSection(
              number: '7',
              title: 'Service Availability',
              body:
                  'Real-time features depend on internet/mobile data, device GPS, and third-party map/routing services. Delays or interruptions may occur due to connectivity, device limits, or external service downtime.',
            ),
            _TermsSection(
              number: '8',
              title: 'No Guarantee of Outcome',
              body:
                  'While the system is designed to improve emergency coordination, response time and outcomes may vary based on traffic, hazard conditions, resource availability, and operational constraints.',
            ),
            _TermsSection(
              number: '9',
              title: 'Authorized Access',
              body:
                  'Access to responder and administrative functions is restricted to authorized personnel. Users must not attempt unauthorized access or interference.',
            ),
            _TermsSection(
              number: '10',
              title: 'System Changes',
              body:
                  'Features, policies, and terms may be updated to improve safety, reliability, and compliance. Continued use after updates constitutes acceptance of revised terms.',
            ),
            _TermsSection(
              number: '11',
              title: 'User Responsibility and Safety',
              body:
                  'During emergencies, users should follow official instructions from responders/LGU personnel and take reasonable safety measures while waiting for assistance.',
            ),
            _TermsSection(
              number: '12',
              title: 'Contact and Reporting',
              body:
                  'For disputes, misuse reports, or policy concerns, users should contact the responsible LGU/emergency operations office.',
            ),
          ],
        ),
      ),
    );
  }
}

class _TermsSection extends StatelessWidget {
  final String number;
  final String title;
  final String body;

  const _TermsSection({
    required this.number,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$number. $title',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}
