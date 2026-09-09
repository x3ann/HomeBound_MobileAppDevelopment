import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/emergency_contact_service.dart';
import '../../services/location_service.dart';
import '../../shared/theme/app_theme.dart';

class SosPanicScreen extends StatefulWidget {
  const SosPanicScreen({super.key});

  @override
  State<SosPanicScreen> createState() => _SosPanicScreenState();
}

class _SosPanicScreenState extends State<SosPanicScreen> {
  static const _emergencyNumber =
      String.fromEnvironment('EMERGENCY_NUMBER', defaultValue: '999');

  final _contactController = TextEditingController();
  final _contactService = EmergencyContactService();
  final _locationService = LocationService.instance;

  LocationResult? _location;
  bool _isSosActive = false;
  bool _isGettingLocation = false;
  bool _isSavingContact = false;
  String? _contactError;

  @override
  void initState() {
    super.initState();
    _loadContact();
  }

  Future<void> _loadContact() async {
    try {
      final saved = await _contactService.load();
      if (mounted && saved != null) _contactController.text = saved;
    } catch (_) {
      // Contact entry still works if device preferences are unavailable.
    }
  }

  @override
  void dispose() {
    _contactController.dispose();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    setState(() => _isGettingLocation = true);
    final result = await _locationService.requestCurrentLocation();
    if (!mounted) return;
    setState(() {
      _location = result;
      _isGettingLocation = false;
    });
    switch (result.status) {
      case LocationStatus.disabled:
        _showMessage('Enable location services to attach your position.');
      case LocationStatus.denied:
        _showMessage('Location permission was denied.');
      case LocationStatus.deniedForever:
        _showMessage('Enable location permission in device settings.');
      case LocationStatus.unavailable:
        _showMessage('A current or last known location was not available.');
      case LocationStatus.available:
        if (result.isLastKnown) {
          _showMessage('Using the last known location; it may be outdated.');
        }
    }
  }

  Future<void> _saveContact() async {
    final value = _contactController.text;
    if (!EmergencyContactService.isValid(value)) {
      setState(() =>
          _contactError = 'Enter 7–15 digits, optionally starting with +.');
      return;
    }
    setState(() {
      _contactError = null;
      _isSavingContact = true;
    });
    try {
      await _contactService.save(value);
      final normalized = EmergencyContactService.normalize(value);
      if (!mounted) return;
      _contactController.text = normalized;
      _showMessage('Emergency contact saved on this device.');
    } catch (_) {
      if (mounted) _showMessage('Unable to save the emergency contact.');
    } finally {
      if (mounted) setState(() => _isSavingContact = false);
    }
  }

  Future<void> _activateSos() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Activate emergency mode?'),
        content: const Text(
          'This prepares the emergency actions but does not place a call or send a message automatically.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Activate')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _isSosActive = true);
    await _getCurrentLocation();
  }

  Future<void> _callEmergencyServices() async {
    try {
      final launched = await launchUrl(
        Uri(scheme: 'tel', path: _emergencyNumber),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) _showMessage('Unable to open the phone dialer.');
    } catch (_) {
      _showMessage('Unable to open the phone dialer on this device.');
    }
  }

  Future<void> _prepareEmergencyMessage() async {
    final contact = _contactController.text;
    if (!EmergencyContactService.isValid(contact)) {
      setState(() => _contactError = 'Enter a valid emergency contact first.');
      _showMessage('Enter and save a valid emergency contact.');
      return;
    }
    final location = _location;
    final position = location?.position;
    if (location?.status != LocationStatus.available || position == null) {
      _showMessage('Get your location before preparing the message.');
      return;
    }
    final message = EmergencyContactService.buildMessage(
      latitude: position.latitude,
      longitude: position.longitude,
      capturedAt: location!.capturedAt ?? DateTime.now(),
      accuracyMeters: location.accuracyMeters,
    );
    try {
      final launched = await launchUrl(
        EmergencyContactService.smsUri(contact: contact, message: message),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) _showMessage('Unable to open the messaging app.');
    } catch (_) {
      _showMessage('Unable to open the messaging app on this device.');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Emergency Assistance',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
          children: [
            _statusCard(),
            const SizedBox(height: 24),
            Center(child: _sosButton()),
            const SizedBox(height: 12),
            Text(
              _isSosActive
                  ? 'MODE ACTIVE — NO ALERT SENT YET'
                  : 'Tap in an emergency',
              textAlign: TextAlign.center,
              style: TextStyle(
                color:
                    _isSosActive ? AppColors.critical : AppColors.textSecondary,
                fontWeight: FontWeight.w800,
                letterSpacing: .8,
              ),
            ),
            const SizedBox(height: 24),
            _locationCard(),
            const SizedBox(height: 14),
            _contactCard(),
            const SizedBox(height: 14),
            _actions(),
            if (_isSosActive) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => setState(() => _isSosActive = false),
                icon: const Icon(Icons.close_rounded),
                label: const Text('Cancel Emergency Mode'),
              ),
            ],
            const SizedBox(height: 18),
            _safetyNotice(),
          ],
        ),
      ),
    );
  }

  Widget _statusCard() => _card(
        child: Row(
          children: [
            Icon(
              _isSosActive ? Icons.warning_rounded : Icons.shield_outlined,
              color: _isSosActive ? AppColors.critical : AppColors.success,
              size: 34,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Emergency status',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(
                    _isSosActive ? 'Actions ready' : 'Emergency mode inactive',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _sosButton() => GestureDetector(
        onTap: _isSosActive ? null : _activateSos,
        child: Container(
          width: 180,
          height: 180,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.critical.withValues(alpha: .15),
            border: Border.all(
                color: AppColors.critical.withValues(alpha: .4), width: 12),
          ),
          padding: const EdgeInsets.all(12),
          child: Container(
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: AppColors.critical),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.sos_rounded, size: 54, color: Colors.white),
                Text(_isSosActive ? 'READY' : 'SOS',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w900)),
              ],
            ),
          ),
        ),
      );

  Widget _locationCard() {
    final location = _location;
    final position = location?.position;
    final available =
        location?.status == LocationStatus.available && position != null;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(icon: Icons.location_on_rounded, text: 'Location'),
          const SizedBox(height: 10),
          Text(_locationText(location),
              style: const TextStyle(color: AppColors.textSecondary)),
          if (available) ...[
            const SizedBox(height: 10),
            SelectableText(
                '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}'),
            const SizedBox(height: 4),
            Text(
              '${location!.isLastKnown ? 'Last known' : 'Current'} · '
              '${location.accuracyMeters == null ? 'accuracy unavailable' : '±${location.accuracyMeters!.round()} m'} · '
              '${_formatTimestamp(location.capturedAt)}',
              style:
                  const TextStyle(color: AppColors.textSecondary, fontSize: 11),
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _isGettingLocation ? null : _getCurrentLocation,
            icon: _isGettingLocation
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.my_location_rounded),
            label: Text(_isGettingLocation ? 'Locating…' : 'Update Location'),
          ),
          if (location?.status == LocationStatus.deniedForever)
            TextButton.icon(
              onPressed: _locationService.openAppSettings,
              icon: const Icon(Icons.settings_rounded),
              label: const Text('Open App Settings'),
            ),
          if (location?.status == LocationStatus.disabled)
            TextButton.icon(
              onPressed: _locationService.openLocationSettings,
              icon: const Icon(Icons.location_disabled_rounded),
              label: const Text('Open Location Settings'),
            ),
        ],
      ),
    );
  }

  Widget _contactCard() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _CardTitle(
                icon: Icons.contact_phone_rounded, text: 'Emergency Contact'),
            const SizedBox(height: 8),
            const Text('Saved only on this device.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: _contactController,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumber],
              onChanged: (_) {
                if (_contactError != null) setState(() => _contactError = null);
              },
              decoration: InputDecoration(
                hintText: 'Example: 0123456789',
                prefixIcon: const Icon(Icons.phone_rounded),
                errorText: _contactError,
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _isSavingContact ? null : _saveContact,
              icon: const Icon(Icons.save_outlined),
              label: Text(_isSavingContact ? 'Saving…' : 'Save Contact'),
            ),
          ],
        ),
      );

  Widget _actions() => Column(
        children: [
          ElevatedButton.icon(
            onPressed: _callEmergencyServices,
            icon: const Icon(Icons.phone_rounded),
            label: const Text('Open Dialer ($_emergencyNumber)'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _prepareEmergencyMessage,
            icon: const Icon(Icons.sms_rounded),
            label: const Text('Prepare Location Message'),
          ),
        ],
      );

  Widget _safetyNotice() => _card(
        color: AppColors.surfaceAlt,
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, color: AppColors.gold),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'The app only opens your dialer or messaging app. Confirm the recipient and location, then place the call or send the message yourself.',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 12, height: 1.45),
              ),
            ),
          ],
        ),
      );

  Widget _card({required Widget child, Color color = AppColors.surface}) =>
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.divider),
        ),
        child: child,
      );

  String _locationText(LocationResult? result) {
    if (_isGettingLocation) return 'Requesting a precise location…';
    if (result == null) return 'Location has not been requested yet.';
    return switch (result.status) {
      LocationStatus.available => result.isLastKnown
          ? 'Using the last known location. Update again if it looks stale.'
          : 'Current location detected.',
      LocationStatus.disabled => 'Location services are disabled.',
      LocationStatus.denied => 'Location permission was denied.',
      LocationStatus.deniedForever =>
        'Location permission must be enabled in Settings.',
      LocationStatus.unavailable => 'No usable location was available.',
    };
  }

  String _formatTimestamp(DateTime? value) {
    if (value == null) return 'time unavailable';
    final local = value.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${local.hour >= 12 ? 'PM' : 'AM'}';
  }
}

class _CardTitle extends StatelessWidget {
  final IconData icon;
  final String text;

  const _CardTitle({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, color: AppColors.gold),
          const SizedBox(width: 9),
          Text(text,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        ],
      );
}
