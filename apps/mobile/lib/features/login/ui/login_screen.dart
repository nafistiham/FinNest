import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/env.dart';
import '../../../app/l10n.dart';
import '../../../app/router.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/bh_bottom_bar.dart';
import '../../../app/widgets/bh_button.dart';
import '../../../app/widgets/brand_mark.dart';
import '../../../app/widgets/demo_note.dart';
import '../../../app/widgets/language_toggle.dart';
import '../../../app/widgets/recipient_row.dart';
import '../../../core/log.dart';
import '../../../data/providers.dart';
import '../../../data/repos/repos.dart';
import '../../apa/logic/apa_insights.dart';
import '../../demo_panel/ui/demo_panel_sheet.dart';
import '../../pay/logic/pay_intent.dart';
import '../../session/logic/session_reset.dart';
import '../logic/biometric_auth.dart';

const _tag = 'login';

/// US-1. The FinNest mark above the
/// two-tone wordmark ([BrandLockup], text-only if the mark is missing), the
/// tagline, two
/// persona rows (name and district; the selected one has a 2 dp `primary`
/// border on `primaryContainer`, no radio), the demo note and the no-OTP
/// trust line. While `PASSKEYS_ENABLED` is false the login is biometric:
/// on a phone with a strong fingerprint or face
/// the one primary 56 dp button is "আঙুলের ছাপ বা মুখ দিয়ে লগইন করুন" with
/// a "log in with password" link under it; on a phone without one the
/// password path shows directly, with a line saying why. Nothing shareable
/// (an OTP) is ever asked for. With the flag on, the passkey button is
/// primary and the labelled "ডেমো লগইন" stays above it. A long press on the
/// logo opens the demo panel.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({this.passkeysEnabled = AppEnv.passkeysEnabled, super.key});

  /// Injectable so the passkey branch is testable without a dart-define.
  final bool passkeysEnabled;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  Persona _persona = Persona.rina;
  bool _busy = false;
  String? _passkeyLine;

  /// The last demo login failed: an error line with a retry, never silence.
  bool _loginFailed = false;

  /// The user chose the password path on a phone with strong biometrics.
  bool _passwordMode = false;

  /// The last biometric prompt failed (wrong finger or face, locked out).
  bool _biometricFailed = false;

  /// Set when a prompt reported biometrics unusable after the strength
  /// check said otherwise; it wins over the checked strength.
  BiometricStrength? _strengthOverride;

  bool _passwordWrong = false;
  bool _obscure = true;
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();

  @override
  void dispose() {
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  static String _nameOf(AppLocalizations l10n, Persona p) => switch (p) {
    Persona.rina => l10n.loginPersonaRina,
    Persona.rahima => l10n.loginPersonaRahima,
  };

  static String _districtOf(AppLocalizations l10n, Persona p) => switch (p) {
    Persona.rina => l10n.loginDistrictRina,
    Persona.rahima => l10n.loginDistrictRahima,
  };

  Future<void> _demoLogin() async {
    setState(() {
      _busy = true;
      _loginFailed = false;
    });
    try {
      // A fresh session per login; whatever a previous persona left behind
      // (cooldowns, last score, evidence quote) is cleared first.
      await resetSessionState(ref.read);
      if (!mounted) return;
      await ref.read(authRepoProvider).demoLogin(_persona);
      if (!mounted) return;
      // A trusted-contact link that arrived signed out (or cold-started the
      // app) opens now instead of being lost.
      context.go(ref.read(pendingLocationProvider).take() ?? Routes.home);
    } on Object catch (e) {
      Log.w(_tag, 'demo login failed', e);
      if (mounted) {
        setState(() {
          _busy = false;
          _loginFailed = true;
        });
      }
    }
  }

  Future<void> _biometricLogin() async {
    final reason = context.l10n.biometricReason;
    setState(() {
      _busy = true;
      _biometricFailed = false;
      _loginFailed = false;
    });
    final outcome = await ref
        .read(biometricAuthProvider)
        .authenticate(reason: reason);
    if (!mounted) return;
    switch (outcome) {
      case BiometricPassed():
        await _demoLogin();
      case BiometricFailed():
        setState(() {
          _busy = false;
          _biometricFailed = true;
        });
      case BiometricCancelled():
        setState(() => _busy = false);
      case BiometricUnavailable(:final reason):
        Log.w(_tag, 'biometric unavailable: $reason');
        setState(() {
          _busy = false;
          _strengthOverride = reason == 'NotEnrolled'
              ? BiometricStrength.notEnrolled
              : BiometricStrength.unsupported;
        });
    }
  }

  void _showPasswordPath(bool on) {
    setState(() {
      _passwordMode = on;
      _biometricFailed = false;
      _passwordWrong = false;
    });
    if (on) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _passwordFocus.requestFocus();
      });
    }
  }

  Future<void> _passwordLogin() async {
    if (_password.text != AppEnv.demoPassword) {
      setState(() => _passwordWrong = true);
      _passwordFocus.requestFocus();
      return;
    }
    setState(() => _passwordWrong = false);
    await _demoLogin();
  }

  static String _fallbackLine(AppLocalizations l10n, BiometricStrength s) =>
      switch (s) {
        BiometricStrength.weakOnly => l10n.loginFallbackWeak,
        BiometricStrength.notEnrolled => l10n.loginFallbackNotEnrolled,
        BiometricStrength.unsupported ||
        BiometricStrength.strong => l10n.loginFallbackUnsupported,
      };

  Future<void> _passkeyLogin() async {
    setState(() => _busy = true);
    final l10n = context.l10n;
    try {
      final result = await ref.read(passkeyAuthProvider).login();
      if (!mounted) return;
      switch (result) {
        case PasskeySuccess():
          // Redeeming the custom token needs Firebase Auth.
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(l10n.passkeyPendingLine)));
        case PasskeyUnavailable(:final reason):
          Log.w(_tag, 'passkey unavailable: $reason');
          setState(() => _passkeyLine = l10n.passkeyUnavailable);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = context.palette;
    final passkeys = widget.passkeysEnabled;

    // Read once per screen; `null` while the few ms of the check run.
    final strength = passkeys
        ? null
        : _strengthOverride ??
              ref
                  .watch(biometricStrengthProvider)
                  .when(
                    data: (s) => s,
                    loading: () => null,
                    error: (_, _) => BiometricStrength.unsupported,
                  );
    final biometricReady = strength == BiometricStrength.strong;
    final passwordPath =
        !passkeys && strength != null && (!biometricReady || _passwordMode);

    final Widget primary;
    if (passkeys) {
      primary = BhButton(
        key: const Key('demo_login'),
        label: l10n.demoLogin,
        icon: Icons.science_outlined,
        variant: BhButtonVariant.outlined,
        onPressed: _busy ? null : _demoLogin,
      );
    } else if (strength == null) {
      primary = BhButton(
        key: const Key('demo_login'),
        label: l10n.loginSubmit,
        icon: Icons.login,
        loading: true,
        onPressed: null,
      );
    } else if (passwordPath) {
      primary = BhButton(
        key: const Key('password_login'),
        label: l10n.loginWithPassword,
        icon: Icons.lock_outline,
        loading: _busy,
        onPressed: _busy ? null : _passwordLogin,
      );
    } else {
      primary = BhButton(
        key: const Key('demo_login'),
        label: l10n.loginBiometric,
        icon: Icons.fingerprint,
        loading: _busy,
        onPressed: _busy ? null : _biometricLogin,
      );
    }
    final demoButton = primary;

    final linkStyle = TextButton.styleFrom(
      minimumSize: const Size.fromHeight(BhSize.touch),
    );
    final Widget? footer = !biometricReady || passkeys
        ? null
        : _passwordMode
        ? TextButton.icon(
            key: const Key('biometric_login_link'),
            style: linkStyle,
            onPressed: _busy ? null : () => _showPasswordPath(false),
            icon: const Icon(Icons.fingerprint),
            label: Text(l10n.loginBiometric),
          )
        : TextButton.icon(
            key: const Key('password_login_link'),
            style: linkStyle,
            onPressed: _busy ? null : () => _showPasswordPath(true),
            icon: const Icon(Icons.lock_outline),
            label: Text(l10n.loginWithPassword),
          );

    return Scaffold(
      bottomNavigationBar: BhBottomBar(
        apaScreen: 'login',
        // Nobody is signed in yet: Apa opens on the five safety rules.
        apaThen: ApaAction.learnRules,
        // Passkeys on: the passkey button is primary and the labelled demo
        // login stays visible above it.
        secondary: passkeys ? demoButton : null,
        footer: footer,
        primary: passkeys
            ? BhButton(
                key: const Key('passkey_login'),
                label: l10n.login,
                icon: Icons.key,
                loading: _busy,
                onPressed: _passkeyLogin,
              )
            : demoButton,
      ),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            BhSpace.m,
            BhSpace.xl,
            BhSpace.m,
            BhSpace.m,
          ),
          children: [
            // Language first, top-right: a reader who cannot read the
            // current script still finds their own language here.
            const Align(
              alignment: AlignmentDirectional.centerEnd,
              child: LanguageToggle(),
            ),
            const SizedBox(height: BhSpace.s),
            const Align(
              alignment: AlignmentDirectional.centerStart,
              child: DemoLongPressTarget(
                child: BrandLockup(wordmarkKey: Key('login_logo')),
              ),
            ),
            const SizedBox(height: BhSpace.xs),
            Text(
              l10n.tagline,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: palette.mutedText,
              ),
            ),
            const SizedBox(height: BhSpace.xl),
            Text(l10n.loginChoosePersona, style: theme.textTheme.titleMedium),
            const SizedBox(height: BhSpace.s),
            for (final p in Persona.values) ...[
              RecipientRow(
                key: Key('persona_${p.uid}'),
                counterparty: Counterparty(
                  acctId: p.uid,
                  nameBn: _nameOf(l10n, p),
                  subtitle: _districtOf(l10n, p),
                ),
                selected: _persona == p,
                trailingChevron: false,
                onTap: _busy ? null : () => setState(() => _persona = p),
              ),
              const SizedBox(height: BhSpace.s),
            ],
            if (passwordPath) ...[
              if (!biometricReady) ...[
                const SizedBox(height: BhSpace.s),
                Text(
                  _fallbackLine(l10n, strength),
                  key: const Key('biometric_fallback_line'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: palette.mutedText,
                  ),
                ),
              ],
              const SizedBox(height: BhSpace.m),
              TextField(
                key: const Key('login_password'),
                controller: _password,
                focusNode: _passwordFocus,
                obscureText: _obscure,
                enableSuggestions: false,
                autocorrect: false,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                enabled: !_busy,
                // Keep the focus on a wrong password: the field stays open.
                onEditingComplete: () {},
                onSubmitted: (_) => _passwordLogin(),
                onChanged: (_) {
                  if (_passwordWrong) setState(() => _passwordWrong = false);
                },
                decoration: InputDecoration(
                  labelText: l10n.loginPasswordLabel,
                  prefixIcon: const Icon(Icons.lock_outline),
                  error: _passwordWrong
                      ? Text(
                          l10n.loginPasswordWrong,
                          key: const Key('password_wrong'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: palette.danger,
                          ),
                        )
                      : null,
                  suffixIcon: IconButton(
                    key: const Key('password_eye'),
                    tooltip: _obscure
                        ? l10n.loginPasswordShow
                        : l10n.loginPasswordHide,
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
            ],
            const SizedBox(height: BhSpace.s),
            DemoNote(
              passwordPath
                  ? l10n.loginDemoPasswordHint(AppEnv.demoPassword)
                  : l10n.demoLoginHint,
            ),
            const SizedBox(height: BhSpace.s),
            Text(
              l10n.loginNoOtp,
              key: const Key('login_no_otp_line'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.mutedText,
              ),
            ),
            if (_biometricFailed) ...[
              const SizedBox(height: BhSpace.m),
              Row(
                key: const Key('biometric_failed'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, color: palette.danger),
                  const SizedBox(width: BhSpace.s),
                  Expanded(
                    child: Text(
                      l10n.loginBiometricFailed,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (_passkeyLine != null) ...[
              const SizedBox(height: BhSpace.m),
              Text(
                _passkeyLine!,
                key: const Key('passkey_unavailable_line'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: palette.warning,
                ),
              ),
            ],
            if (_loginFailed) ...[
              const SizedBox(height: BhSpace.m),
              Column(
                key: const Key('login_failed'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline, color: palette.danger),
                      const SizedBox(width: BhSpace.s),
                      Expanded(
                        child: Text(
                          l10n.loginFailed,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: palette.danger,
                          ),
                        ),
                      ),
                    ],
                  ),
                  TextButton.icon(
                    key: const Key('login_retry'),
                    onPressed: _busy ? null : _demoLogin,
                    icon: const Icon(Icons.refresh),
                    label: Text(l10n.retry),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
