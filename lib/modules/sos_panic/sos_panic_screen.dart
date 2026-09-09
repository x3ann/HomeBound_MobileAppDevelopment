import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../shared/theme/app_theme.dart';

class SosPanicScreen extends StatefulWidget {
  const SosPanicScreen({super.key});

  @override
  State<SosPanicScreen> createState() => _SosPanicScreenState();
}

class _SosPanicScreenState extends State<SosPanicScreen> {
  final TextEditingController _contactController = TextEditingController();

  Position? _currentPosition;
  bool _isSosActive = false;
  bool _isGettingLocation = false;

  String _locationStatus = 'Location not retrieved yet';

  @override
  void dispose() {
    _contactController.dispose();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    setState(() {
      _isGettingLocation = true;
      _locationStatus = 'Getting current location...';
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        setState(() {
          _isGettingLocation = false;
          _locationStatus = 'Location services are disabled.';
        });

        _showMessage('Please enable location services.');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        setState(() {
          _isGettingLocation = false;
          _locationStatus = 'Location permission was denied.';
        });

        _showMessage('Location permission is required for SOS.');
        return;
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _isGettingLocation = false;
          _locationStatus = 'Location permission is permanently denied.';
        });

        _showMessage('Please enable location permission in Settings.');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (!mounted) return;

      setState(() {
        _currentPosition = position;
        _isGettingLocation = false;
        _locationStatus = 'Current location detected';
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _isGettingLocation = false;
        _locationStatus = 'Unable to retrieve current location.';
      });

      _showMessage('Unable to get your current location.');
    }
  }

  Future<void> _activateSos() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: AppColors.critical,
              ),
              SizedBox(width: 10),
              Text('Activate SOS?'),
            ],
          ),
          content: const Text(
            'This will activate emergency mode. '
                'You can then call emergency services or prepare '
                'an SOS message for your emergency contact.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context, false);
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context, true);
              },
              child: const Text('Activate SOS'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    setState(() {
      _isSosActive = true;
    });

    await _getCurrentLocation();
  }

  void _cancelSos() {
    setState(() {
      _isSosActive = false;
    });

    _showMessage('SOS emergency mode cancelled.');
  }

  Future<void> _callEmergencyServices() async {
    final uri = Uri(
      scheme: 'tel',
      path: '999',
    );

    final launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );

    if (!launched) {
      _showMessage('Unable to open the phone dialer.');
    }
  }

  Future<void> _sendEmergencyMessage() async {
    final contact = _contactController.text.trim();

    if (contact.isEmpty) {
      _showMessage('Please enter an emergency contact number.');
      return;
    }

    if (_currentPosition == null) {
      _showMessage('Please get your current location first.');
      return;
    }

    final latitude = _currentPosition!.latitude.toStringAsFixed(6);
    final longitude = _currentPosition!.longitude.toStringAsFixed(6);

    final message =
        'SOS! I may need help. My current location is: '
        'https://maps.google.com/?q=$latitude,$longitude';

    final uri = Uri(
      scheme: 'sms',
      path: contact,
      queryParameters: {
        'body': message,
      },
    );

    final launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );

    if (!launched) {
      _showMessage('Unable to open the messaging app.');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'SOS Panic Button',
          style: TextStyle(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
          children: [
            _buildStatusCard(),
            const SizedBox(height: 30),
            Center(
              child: _buildSosButton(),
            ),
            const SizedBox(height: 18),
            Text(
              _isSosActive
                  ? 'SOS MODE ACTIVE'
                  : 'Tap the button in an emergency',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _isSosActive
                    ? AppColors.critical
                    : AppColors.textSecondary,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 30),
            _buildLocationCard(),
            const SizedBox(height: 16),
            _buildEmergencyContactCard(),
            const SizedBox(height: 16),
            _buildEmergencyActions(),
            if (_isSosActive) ...[
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: _cancelSos,
                icon: const Icon(Icons.close_rounded),
                label: const Text('Cancel SOS'),
              ),
            ],
            const SizedBox(height: 22),
            _buildSafetyNotice(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final active = _isSosActive;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: active ? AppColors.critical : AppColors.divider,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: active
                  ? AppColors.critical.withValues(alpha: 0.15)
                  : AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              active
                  ? Icons.warning_rounded
                  : Icons.shield_outlined,
              color: active
                  ? AppColors.critical
                  : AppColors.success,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Emergency Status',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  active
                      ? 'SOS Active'
                      : 'You are currently safe',
                  style: TextStyle(
                    color: active
                        ? AppColors.critical
                        : AppColors.success,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSosButton() {
    final active = _isSosActive;

    return GestureDetector(
      onTap: active ? null : _activateSos,
      child: Container(
        width: 190,
        height: 190,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.critical.withValues(
            alpha: active ? 0.20 : 0.12,
          ),
          border: Border.all(
            color: AppColors.critical.withValues(alpha: 0.35),
            width: 12,
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.critical.withValues(alpha: 0.20),
              blurRadius: 35,
              spreadRadius: 8,
            ),
          ],
        ),
        child: Container(
          margin: const EdgeInsets.all(12),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.critical,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.sos_rounded,
                size: 56,
                color: Colors.white,
              ),
              const SizedBox(height: 5),
              Text(
                active ? 'ACTIVE' : 'SOS',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 25,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLocationCard() {
    final position = _currentPosition;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppColors.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.location_on_rounded,
                color: AppColors.gold,
              ),
              SizedBox(width: 10),
              Text(
                'Current Location',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            _locationStatus,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
          if (position != null) ...[
            const SizedBox(height: 12),
            Text(
              'Latitude: ${position.latitude.toStringAsFixed(6)}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              'Longitude: ${position.longitude.toStringAsFixed(6)}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed:
              _isGettingLocation ? null : _getCurrentLocation,
              icon: _isGettingLocation
                  ? const SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                ),
              )
                  : const Icon(
                Icons.my_location_rounded,
                color: AppColors.gold,
              ),
              label: Text(
                _isGettingLocation
                    ? 'Getting Location...'
                    : 'Get Current Location',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmergencyContactCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppColors.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.contact_phone_rounded,
                color: AppColors.gold,
              ),
              SizedBox(width: 10),
              Text(
                'Emergency Contact',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Enter a phone number to prepare an SOS message.',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _contactController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              hintText: 'Example: 0123456789',
              prefixIcon: Icon(Icons.phone_rounded),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmergencyActions() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _callEmergencyServices,
            icon: const Icon(Icons.phone_rounded),
            label: const Text(
              'Call Emergency Services (999)',
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _sendEmergencyMessage,
            icon: const Icon(
              Icons.sms_rounded,
              color: AppColors.gold,
            ),
            label: const Text(
              'Prepare SOS Message',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSafetyNotice() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(15),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: AppColors.gold,
            size: 20,
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'HomeBound opens your phone dialer or messaging app. '
                  'You must confirm the call or send the message yourself.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}