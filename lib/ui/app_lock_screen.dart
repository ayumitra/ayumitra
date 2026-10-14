import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_lock.dart';

/// Place above the app's MaterialApp so this observer handles system back
/// before its Navigator. The private app remains mounted behind an opaque
/// root overlay, including any open file, share, profile or measurements route.
class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.controller,
    required this.child,
    this.privacyChannel = const MethodChannel('app.ayumitra/app_lock'),
  });
  final AppLockController controller;
  final Widget child;
  final MethodChannel privacyChannel;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  final _pin = TextEditingController();
  bool _inactive = false;
  bool _submitting = false;
  String? _actionError;
  Timer? _cooldownTick;
  int _lifecycleEpoch = 0;
  int _actionEpoch = 0;
  bool? _nativeEnabled;
  Future<void> _nativeWork = Future.value();

  bool get _covered =>
      _inactive || !widget.controller.initialized || widget.controller.locked;
  bool get _working => _submitting || widget.controller.busy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _inactive = state != null && state != AppLifecycleState.resumed;
    widget.controller.addListener(_changed);
    _syncNativePrivacy();
    _updateCooldownTimer();
    _releaseNativeShieldAfterFrame();
  }

  @override
  void didUpdateWidget(AppLockGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _actionEpoch++;
      _pin.clear();
      _submitting = false;
      _actionError = null;
      _nativeEnabled = null;
      _syncNativePrivacy();
      _updateCooldownTimer();
      _releaseNativeShieldAfterFrame();
    }
  }

  void _native(String method, Map<String, bool> arguments) {
    final channel = widget.privacyChannel;
    // Preserve ordering across rapid background/resume/configuration events.
    // A missing native channel in a host preview must not reveal the child or
    // log secrets; the opaque Flutter gate remains the access boundary.
    _nativeWork = _nativeWork.then((_) async {
      if (!mounted) return;
      try {
        await channel.invokeMethod<bool>(method, arguments);
      } catch (_) {}
    });
  }

  void _syncNativePrivacy() {
    final lock = widget.controller;
    final protect = !lock.initialized || lock.enabled || lock.locked;
    if (_nativeEnabled == protect) return;
    _nativeEnabled = protect;
    _native('setPrivacyEnabled', {'enabled': protect});
  }

  void _releaseNativeShieldAfterFrame() {
    final epoch = _lifecycleEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _inactive || epoch != _lifecycleEpoch) return;
      // iOS retains its native app-switcher cover after becoming active. Only
      // remove it once this frame contains the lock/loading layer or the
      // authenticated app. A stale resume callback cannot uncover a new pause.
      _native('setPrivacyVisible', {'visible': false});
    });
  }

  void _changed() {
    if (!mounted) return;
    _syncNativePrivacy();
    _updateCooldownTimer();
    if (!widget.controller.locked) _pin.clear();
    setState(() {});
    _releaseNativeShieldAfterFrame();
  }

  void _updateCooldownTimer() {
    if (!widget.controller.locked ||
        widget.controller.cooldownRemaining <= Duration.zero) {
      _cooldownTick?.cancel();
      _cooldownTick = null;
      return;
    }
    _cooldownTick ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _updateCooldownTimer();
      setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    _lifecycleEpoch++;
    if (state == AppLifecycleState.resumed) {
      setState(() => _inactive = false);
      _releaseNativeShieldAfterFrame();
      return;
    }
    setState(() => _inactive = true);
    if (_nativeEnabled != false) {
      _native('setPrivacyVisible', {'visible': true});
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _actionEpoch++;
      _submitting = false;
      _actionError = null;
      _pin.clear();
      FocusManager.instance.primaryFocus?.unfocus();
      widget.controller.lockForBackground();
    }
    // Inactive alone includes biometric prompts and system dialogs. Shield
    // immediately, but preserve the current authentication until a real pause.
  }

  @override
  Future<bool> didPopRoute() async => _covered;

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) => _covered;

  @override
  void handleCommitBackGesture() {
    // A gesture claimed while covered must never pop a private route, even
    // if authentication completed between its start and commit.
  }

  Future<void> _run(Future<void> Function(AppLockController) action) async {
    if (_working) return;
    final lock = widget.controller;
    final epoch = ++_actionEpoch;
    setState(() {
      _submitting = true;
      _actionError = null;
    });
    try {
      await action(lock);
    } catch (_) {
      if (mounted && epoch == _actionEpoch) {
        _actionError = 'Unlocking could not finish. Please try again.';
      }
    } finally {
      if (mounted && epoch == _actionEpoch && widget.controller == lock) {
        _pin.clear();
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _unlockPin() => _run((lock) async {
    if (lock.cooldownRemaining > Duration.zero) return;
    await lock.unlockWithPin(_pin.text);
  });

  @override
  void dispose() {
    _lifecycleEpoch++;
    _actionEpoch++;
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    _cooldownTick?.cancel();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(
          excluding: _covered,
          child: ExcludeFocus(
            excluding: _covered,
            child: IgnorePointer(
              ignoring: _covered,
              child: TickerMode(enabled: !_covered, child: widget.child),
            ),
          ),
        ),
        if (_covered)
          Positioned.fill(
            child: MaterialApp(
              key: const ValueKey('app-lock-overlay'),
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                useMaterial3: true,
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xff477c68),
                ),
                scaffoldBackgroundColor: const Color(0xfff7f8f2),
              ),
              home: PopScope(canPop: false, child: _lockLayer()),
            ),
          ),
      ],
    ),
  );

  Widget _lockLayer() {
    final lock = widget.controller;
    final waiting = _inactive || !lock.initialized;
    final retryLoad = lock.needsReload || lock.mode == AppLockMode.off;
    final remaining = lock.cooldownRemaining;
    final coolingDown = remaining > Duration.zero;
    final seconds = (remaining.inMilliseconds / 1000).ceil();
    final error = _actionError ?? lock.error;
    return Scaffold(
      key: const ValueKey('app-lock-screen'),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.lock_outline,
                    size: 46,
                    color: Color(0xff203f38),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    waiting ? 'Ayumitra' : 'Unlock Ayumitra',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    waiting
                        ? 'Your private companion'
                        : 'Your profiles and records stay hidden until you unlock.',
                    textAlign: TextAlign.center,
                  ),
                  if (!lock.initialized && !_inactive) ...[
                    const SizedBox(height: 24),
                    const Center(child: CircularProgressIndicator()),
                  ],
                  if (!waiting) ...[
                    const SizedBox(height: 24),
                    if (!retryLoad && lock.mode == AppLockMode.pin) ...[
                      TextField(
                        key: const ValueKey('app-lock-pin'),
                        controller: _pin,
                        obscureText: true,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        autocorrect: false,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(12),
                        ],
                        enabled: !_working && !coolingDown,
                        decoration: const InputDecoration(
                          labelText: 'App PIN',
                          helperText: 'Enter your 6 to 12 digit PIN.',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => unawaited(_unlockPin()),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        key: const ValueKey('app-lock-unlock'),
                        onPressed: _working || coolingDown ? null : _unlockPin,
                        child: const Text('Unlock'),
                      ),
                    ],
                    if (!retryLoad && lock.mode == AppLockMode.device)
                      FilledButton.icon(
                        key: const ValueKey('app-lock-device'),
                        icon: const Icon(Icons.fingerprint),
                        label: const Text('Unlock with your device'),
                        onPressed: _working
                            ? null
                            : () => _run((controller) async {
                                await controller.unlockWithDevice();
                              }),
                      ),
                    if (retryLoad)
                      FilledButton.icon(
                        key: const ValueKey('app-lock-retry'),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry loading app lock'),
                        onPressed: _working
                            ? null
                            : () =>
                                  _run((controller) => controller.initialize()),
                      ),
                    if (coolingDown) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Try again in $seconds seconds.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (_working) ...[
                      const SizedBox(height: 16),
                      const Center(child: CircularProgressIndicator()),
                    ],
                    if (error != null && error.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        error,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xff8f3d2f)),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
