import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_lock.dart';

/// App-wide access control. There is no account or remote PIN recovery.
class SecuritySettingsScreen extends StatefulWidget {
  const SecuritySettingsScreen({super.key, required this.controller});
  final AppLockController controller;

  @override
  State<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState extends State<SecuritySettingsScreen> {
  AppLockController get lock => widget.controller;
  bool changing = false;
  Completer<bool>? _authentication;

  @override
  void initState() {
    super.initState();
    lock.addListener(_changed);
  }

  void _changed() {
    if (_authentication != null && !lock.locked && lock.initialized) {
      _authentication!.complete(true);
      _authentication = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    lock.removeListener(_changed);
    _authentication?.complete(false);
    _authentication = null;
    super.dispose();
  }

  Future<bool> _reauthenticate() async {
    if (!lock.enabled) return true;
    final authentication = Completer<bool>();
    _authentication = authentication;
    lock.lock();
    return authentication.future;
  }

  Future<void> _change(Future<void> Function() change) async {
    if (changing || lock.busy) return;
    setState(() => changing = true);
    try {
      if (!await _reauthenticate() || !mounted) return;
      await change();
    } finally {
      if (mounted) setState(() => changing = false);
    }
  }

  Future<void> _setPin() => _change(() async {
    final pin = await showDialog<String>(
      context: context,
      builder: (_) => const _PinSetupDialog(),
    );
    if (pin != null && mounted) await lock.configurePin(pin);
  });

  @override
  Widget build(BuildContext context) {
    final disabled = changing || lock.busy;
    final mode = switch (lock.mode) {
      AppLockMode.off => 'Off',
      AppLockMode.pin => 'App PIN',
      AppLockMode.device => 'Device biometrics or screen lock',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Security and privacy')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Icon(Icons.lock_outline, size: 44),
          const SizedBox(height: 12),
          Text(
            'App lock · $mode',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Protect every profile, conversation and file. When enabled, leaving Ayumitra locks the app. Authentication happens on your phone; Ayumitra never receives your fingerprints or face data.',
          ),
          const SizedBox(height: 24),
          ListTile(
            key: const Key('security-set-pin'),
            leading: const Icon(Icons.pin_outlined),
            title: Text(
              lock.mode == AppLockMode.pin
                  ? 'Change app PIN'
                  : 'Use an app PIN',
            ),
            subtitle: const Text(
              'A private 6–12 digit PIN, with retry limits.',
            ),
            onTap: disabled ? null : _setPin,
          ),
          ListTile(
            key: const Key('security-use-device'),
            leading: const Icon(Icons.fingerprint),
            title: const Text('Use device biometrics'),
            subtitle: const Text(
              'Face, fingerprint, or your phone’s screen lock as a fallback.',
            ),
            onTap: disabled
                ? null
                : () => _change(() async {
                    await lock.configureDevice();
                  }),
          ),
          if (lock.enabled) ...[
            ListTile(
              key: const Key('security-lock-now'),
              leading: const Icon(Icons.lock),
              title: const Text('Lock now'),
              onTap: disabled ? null : lock.lock,
            ),
            ListTile(
              key: const Key('security-disable'),
              leading: const Icon(Icons.lock_open),
              title: const Text('Turn off app lock'),
              subtitle: const Text(
                'Authenticate with your current lock first.',
              ),
              onTap: disabled
                  ? null
                  : () => _change(() async {
                      await lock.disable();
                    }),
            ),
          ],
          if (lock.busy) const LinearProgressIndicator(),
          if (lock.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                lock.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 20),
          const Text(
            'Your original medical files remain on-device. Public search and optional cloud AI have separate sharing controls. App lock protects access to this app; it does not change the sharing choice you make for those tools.',
          ),
        ],
      ),
    );
  }
}

class _PinSetupDialog extends StatefulWidget {
  const _PinSetupDialog();
  @override
  State<_PinSetupDialog> createState() => _PinSetupDialogState();
}

class _PinSetupDialogState extends State<_PinSetupDialog> {
  final first = TextEditingController();
  final second = TextEditingController();
  String? error;
  @override
  void dispose() {
    first.clear();
    second.clear();
    first.dispose();
    second.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Set your app PIN'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Choose 6–12 digits. This PIN stays on your device and cannot be recovered. Remember it before enabling the lock.',
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('security-new-pin'),
            controller: first,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 12,
            decoration: const InputDecoration(labelText: 'New PIN'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('security-confirm-pin'),
            controller: second,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 12,
            decoration: const InputDecoration(labelText: 'Confirm PIN'),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('security-save-pin'),
        onPressed: () {
          if (!RegExp(r'^\d{6,12}$').hasMatch(first.text)) {
            setState(() => error = 'Use 6–12 digits.');
          } else if (first.text != second.text) {
            setState(() => error = 'The PINs do not match.');
          } else {
            Navigator.pop(context, first.text);
          }
        },
        child: const Text('Enable PIN lock'),
      ),
    ],
  );
}
