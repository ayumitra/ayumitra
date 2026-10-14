# App lock (optional, local-only)

Ayumitra's records are already encrypted at rest. The optional app lock adds
an **app-access gate**: proving it is you before the app shows anything.
It is off by default and never a sign-in, account, or cloud check.

## User guide

- **Off by default.** Nothing changes until you enable it in
  Settings → App lock · all profiles (Security and privacy).
- **Two modes:** device biometrics / screen lock (fingerprint, face, PIN,
  pattern — whatever secures the phone), or an app PIN of 6–12 digits.
- **Changing or disabling an existing lock requires authenticating first.**
  Initial PIN setup requires confirmation; device-mode setup verifies the
  phone’s existing authentication before enabling protection.
- **Wrong attempts slow down.** Consecutive wrong PINs incur growing delays
  after five attempts, capped at 15 minutes between further attempts.
- **No remote recovery.** There is no "forgot PIN" email or server reset —
  no account service receives the PIN. There is no in-app PIN recovery or
  destructive reset. Remember your PIN, or choose device authentication so
  the operating system manages your recovery options.
- **Lock moments:** leaving the app (background), the app-switcher view,
  and every cold start. Every profile and route sits behind the same gate.
- **What it does NOT do:** it does not re-encrypt the vault with your PIN
  and does not move the vault key into hardware. Vault encryption is
  unchanged (AES with a key in Keystore/Keychain). The lock guards *access*;
  a lost unlocked phone is still only as safe as its OS lock.
- **Screenshots:** on Android the app hides its content from screenshots and
  the recent-apps thumbnail while app lock is enabled. On iOS, a native
  cover hides inactive app-switcher snapshots; screenshots taken while the
  app is unlocked remain possible. Neither platform prevents an external
  camera from photographing an unlocked screen.

## Developer notes

- **Verifier, not plaintext:** the PIN is verified against a locally stored
  salted slow-hash (PBKDF2); the PIN itself is never persisted. Salt and
  parameters live alongside the verifier in secure storage.
- **Throttling state machine:** consecutive failures back off (growing
  delay, capped), tracked in secure storage so reinstall-free resets cannot
  bypass it; success resets the counter. Keep the delay UI truthful — never
  show unlocked content during a delay.
- **Lifecycle gate:** lock on actual background transitions (`paused`,
  `hidden`, or `detached`). An `inactive` transition alone immediately shields
  content without cancelling a biometric or permission prompt. External camera
  and file-picker activities can background the app and require unlocking on
  return. In-flight imports, processing jobs, and model work keep running;
  only the UI is shielded. Gate every route, including deep links, dialogs,
  and the app-switcher snapshot.
- **Shielding:** Android `FLAG_SECURE` on sensitive windows (blocks
  screenshots *and* the recents thumbnail). iOS: hide content in
  `applicationWillResignActive` / snapshot callbacks — accept the platform
  limitation above and document it in-app rather than promising prevention.
- **Fallback:** "device" mode delegates to OS screen-lock/biometric APIs
  (`local_auth`); if the device has no secure lock enrolled, refuse device
  mode with guidance instead of silently downgrading to no lock.
- **Scope discipline:** app-lock code must never see health content, keys, or
  vault bytes — it returns allow/deny only. No analytics on attempts beyond
  a local counter. All strings user-facing and explicit that this is an
  access lock, not new encryption.
- **Test angles (Main runs):** enabling/changing/disabling each require auth;
  throttle survives process kill; background/foreground matrix per OS;
  recents-thumbnail blank on Android; vault bytes unchanged by lock changes;
  no health content in lock logging.

The retry delay uses the device clock; clock changes can affect its duration.
The app-access gate is not a defense against a compromised operating system or
an attacker who can alter secure-storage state. No authentication data is sent
to an AI provider. Optional cloud sharing remains a separate user choice.

Authentication integration uses the official Flutter
[local_auth documentation](https://pub.dev/packages/local_auth).
