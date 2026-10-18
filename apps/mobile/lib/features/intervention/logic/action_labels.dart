import '../../../app/l10n.dart';
import '../../../data/contracts/score.dart';

/// Button labels keyed by `actions[].type` (FR-3: the only copy the client
/// composes). Numbers come from the server's `params` and are interpolated
/// through ARB placeholders, in Bangla digits for the Bangla locale. Unknown
/// types are never dropped: they get the generic label (the raw type is a
/// developer string and stays in the log, not on screen).
abstract final class ActionLabels {
  static const holdTransaction = 'hold_transaction';
  static const freezePinReset = 'freeze_pin_reset';
  static const delayNewPayee = 'delay_new_payee';
  static const trustedContactCheck = 'trusted_contact_check';
  static const stepUpVerification = 'step_up_verification';
  static const blockTransaction = 'block_transaction';

  /// The client-only action that opens the Apa sheet from the overlay.
  static const askApa = 'ask_apa';

  /// The client-only identity step-up on a behaviour hold: offered only when `stepUpFor` says so, rendered outlined.
  static const biometricStepUp = 'biometric_step_up';

  /// The client-only "ঠিক আছে" on a block:
  /// the money is already stopped, so the primary only closes the overlay.
  static const acknowledge = 'acknowledge';

  /// The one filled button on an overlay: the outcome the server already
  /// chose (money stays / sends later / PIN reset frozen / "ঠিক আছে" on a
  /// block). Everything else is secondary.
  static bool isPrimary(String type) => switch (type) {
    holdTransaction ||
    delayNewPayee ||
    freezePinReset ||
    blockTransaction ||
    acknowledge => true,
    _ => false,
  };

  static String labelFor(AppLocalizations l10n, ActionItem a) =>
      switch (a.type) {
        // The server's minutes are the analyst window, not something the
        // customer acts on: the button names the outcome she gets.
        holdTransaction => l10n.actionKeepMoney,
        freezePinReset => l10n.actionFreezePinReset(_num(l10n, a, 'minutes')),
        delayNewPayee => l10n.actionDelayNewPayee(_num(l10n, a, 'minutes')),
        // Without a server expiry (the client keeps the action visible for
        // an identity hold) the label carries no number at all.
        trustedContactCheck =>
          a.params['expires_in_minutes'] == null
              ? l10n.stepUpAskTrusted
              : l10n.actionTrustedContact(_num(l10n, a, 'expires_in_minutes')),
        stepUpVerification => l10n.actionStepUp,
        blockTransaction => l10n.actionBlock,
        askApa => l10n.askApa,
        biometricStepUp => l10n.stepUpBiometricButton,
        acknowledge => l10n.ok,
        _ => l10n.actionUnknown,
      };

  /// Whether the type is one the client knows how to label.
  static bool isKnown(String type) => switch (type) {
    holdTransaction ||
    freezePinReset ||
    delayNewPayee ||
    trustedContactCheck ||
    stepUpVerification ||
    blockTransaction ||
    askApa ||
    biometricStepUp ||
    acknowledge => true,
    _ => false,
  };

  /// A numeric param rendered in the locale's digits; `—` when the server
  /// omitted it (the copy never invents a number).
  static String _num(AppLocalizations l10n, ActionItem a, String key) {
    final v = a.params[key];
    final String s;
    if (v is int) {
      s = v.toString();
    } else if (v is double) {
      s = v == v.roundToDouble() ? v.round().toString() : v.toString();
    } else if (v is String && v.isNotEmpty) {
      s = v;
    } else {
      return '—';
    }
    return l10n.localeName.startsWith('bn') ? bnDigits(s) : s;
  }
}
