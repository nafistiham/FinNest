import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dates.dart';
import '../../../app/env.dart';
import '../../../app/l10n.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/bh_bottom_bar.dart';
import '../../../app/widgets/bh_button.dart';
import '../../../app/widgets/demo_note.dart';
import '../../../app/widgets/digit_slots.dart';
import '../../../app/widgets/empty_state.dart';
import '../../../app/widgets/step_progress.dart';
import '../../../core/clock.dart';
import '../../../core/haptics.dart';
import '../../../core/ids.dart';
import '../../../core/log.dart';
import '../../../data/native/bhorosha_native.dart';
import '../../../data/providers.dart';
import '../../../data/repos/repos.dart';
import '../../send_money/logic/risk_providers.dart' show clockProvider;
import '../logic/pay_controller.dart';
import '../logic/pay_ledger.dart';
import '../logic/pay_paths.dart';
import '../logic/pay_rules.dart';

/// Cash in, step 2 of 2: a reference code to show the
/// agent. Opening it writes a `cash_in` row with status `requested`, which
/// never moves the balance; the demo panel's "এজেন্ট ক্যাশ ইন নিশ্চিত
/// করলেন" (`LedgerRepo.confirmCashIn`) turns it `done` and the balance rises.
/// The code is valid for 15 minutes; if the countdown ends while this screen
/// is open the row becomes `cancelled`.
///
/// The countdown is derived from the injected clock on every tick
/// (`expiresAt - now`), so it never drifts after the app was backgrounded,
/// and it lives in its own small widget so a tick repaints the time only.
/// If the row cannot be written the code is not shown at all: the agent
/// could never confirm it (never fail silently); an empty state
/// offers a retry.
///
/// The square under the code is decorative, drawn once from the code's
/// SHA-256, and labelled "ডেমো কোড — আসল QR নয়" so nobody tries to scan it.
class CashInCodeScreen extends ConsumerStatefulWidget {
  const CashInCodeScreen({this.haptics = const SystemHaptics(), super.key});

  final Haptics haptics;

  @override
  ConsumerState<CashInCodeScreen> createState() => _CashInCodeScreenState();
}

class _CashInCodeScreenState extends ConsumerState<CashInCodeScreen> {
  static const _tag = 'cash_in';

  String? _code;
  String? _txnId;
  DateTime? _expiresAt;
  bool _expired = false;
  bool _writeFailed = false;
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    unawaited(ref.read(nativeProvider).setSecure(AppEnv.secureScreensEnabled));
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  /// Mints a code and writes the `requested` row; the code shows only once
  /// the write succeeded. A retry mints a fresh code.
  Future<void> _start() async {
    if (!mounted || _writing) return;
    final intent = ref.read(payControllerProvider);
    final user = ref.read(currentUserProvider).value;
    if (intent.kind != PayKind.cashIn ||
        intent.amountBdt <= 0 ||
        user == null) {
      context.go(PayPaths.start(PayKind.cashIn));
      return;
    }
    final code = PayRules.newCashInCode();
    final txnId = newId('txn');
    final now = ref.read(clockProvider).now();
    setState(() {
      _writing = true;
      _writeFailed = false;
    });
    try {
      await ref
          .read(ledgerRepoProvider)
          .create(
            user.uid,
            PayLedger.rowFor(
              intent,
              user,
              txnId: txnId,
              ts: now,
              status: LedgerStatus.requested,
              cashInCode: code,
            ),
          );
      if (!mounted) return;
      setState(() {
        _writing = false;
        _code = code;
        _txnId = txnId;
        _expiresAt = now.add(PayRules.cashInTtl);
      });
    } on Object catch (e) {
      Log.w(_tag, 'cash-in row write failed', e);
      if (!mounted) return;
      setState(() {
        _writing = false;
        _writeFailed = true;
      });
    }
  }

  Future<void> _expire() async {
    final id = _txnId;
    if (id == null || _expired) return;
    final rows = ref.read(payRecentRowsProvider).value ?? const <LedgerTxn>[];
    final row = rows.where((t) => t.txnId == id).firstOrNull;
    if (row != null && !row.isRequestedCashIn) return;
    setState(() => _expired = true);
    try {
      await ref.read(ledgerRepoProvider).setStatus(id, LedgerStatus.cancelled);
    } on Object catch (e) {
      Log.w(_tag, 'cash-in expiry write failed', e);
    }
  }

  bool _confirmedIn(AsyncValue<List<LedgerTxn>> rows) {
    final id = _txnId;
    if (id == null) return false;
    final row = (rows.value ?? const <LedgerTxn>[])
        .where((t) => t.txnId == id)
        .firstOrNull;
    return row?.status == LedgerStatus.done;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final amount = ref.watch(payControllerProvider).amountBdt;
    // The agent confirmed: one success haptic on the transition, not on
    // every rebuild.
    ref.listen<AsyncValue<List<LedgerTxn>>>(payRecentRowsProvider, (
      before,
      after,
    ) {
      if (_confirmedIn(after) && (before == null || !_confirmedIn(before))) {
        unawaited(widget.haptics.success());
      }
    });
    final confirmed = _confirmedIn(ref.watch(payRecentRowsProvider));
    final code = _code;
    final expiresAt = _expiresAt;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cashInCodeTitle),
        leading: BackButton(onPressed: () => context.go(PayPaths.home)),
      ),
      bottomNavigationBar: BhBottomBar(
        apaScreen: 'cashin',
        primary: BhButton(
          key: const Key('cashin_home'),
          label: l10n.goHome,
          icon: Icons.home_outlined,
          onPressed: () => context.go(PayPaths.home),
        ),
      ),
      body: Column(
        children: [
          const StepProgress(step: 2, total: 2),
          Expanded(
            child: _writeFailed
                ? ListView(
                    padding: const EdgeInsets.all(BhSpace.m),
                    children: [
                      EmptyState(
                        key: const Key('cashin_write_failed'),
                        icon: Icons.cloud_off,
                        title: l10n.cashInWriteFailed,
                        body: l10n.safetyErrorBody,
                        actionLabel: l10n.retry,
                        onAction: _start,
                      ),
                    ],
                  )
                : ListView(
                    padding: const EdgeInsets.all(BhSpace.m),
                    children: [
                      DemoNote(l10n.cashInDemoCode),
                      const SizedBox(height: BhSpace.l),
                      if (code != null) ...[
                        Center(
                          child: Text(
                            context.digits(code),
                            key: const Key('cashin_code'),
                            style: text.displaySmall?.copyWith(
                              color: p.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(height: BhSpace.m),
                        Center(
                          child: Semantics(
                            label: l10n.cashInDemoCode,
                            child: CodeGrid(code: code, color: p.onSurface),
                          ),
                        ),
                      ],
                      const SizedBox(height: BhSpace.m),
                      Center(
                        child: TakaSlots(
                          amount: amount,
                          style: context.textRoles.amountHero.copyWith(
                            color: p.onSurface,
                          ),
                          signColor: p.mutedText,
                        ),
                      ),
                      const SizedBox(height: BhSpace.s),
                      if (confirmed)
                        _StatusLine(
                          key: const Key('cashin_confirmed'),
                          text: l10n.cashInConfirmed,
                          fill: p.successContainer,
                          ink: p.onSuccessContainer,
                          icon: Icons.check_circle_outline,
                        )
                      else if (_expired)
                        _StatusLine(
                          key: const Key('cashin_expired'),
                          text: l10n.cashInCodeExpired,
                          fill: p.surfaceVariant,
                          ink: p.mutedText,
                          icon: Icons.timer_off_outlined,
                        )
                      else if (expiresAt != null) ...[
                        CashInCountdown(
                          key: const Key('cashin_countdown'),
                          expiresAt: expiresAt,
                          clock: ref.watch(clockProvider),
                          onExpired: () => unawaited(_expire()),
                        ),
                        const SizedBox(height: BhSpace.m),
                        Text(
                          l10n.cashInShowAgent,
                          textAlign: TextAlign.center,
                          style: text.bodyMedium,
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// "সময় বাকি ১৪:৫৮ · মেয়াদ শেষ দুপুর ১২:৪৫": the seconds left are read
/// from [clock] on every tick, never counted down, so a backgrounded app
/// shows the right time when it comes back. Calls [onExpired] once when
/// the time is up and stops ticking.
class CashInCountdown extends StatefulWidget {
  const CashInCountdown({
    required this.expiresAt,
    required this.clock,
    required this.onExpired,
    super.key,
  });

  final DateTime expiresAt;
  final Clock clock;
  final VoidCallback onExpired;

  @override
  State<CashInCountdown> createState() => _CashInCountdownState();
}

class _CashInCountdownState extends State<CashInCountdown> {
  Timer? _timer;
  bool _fired = false;

  /// Whole seconds left, rounded up: the code opens at "15:00", not at
  /// "14:59" a few milliseconds after it was minted.
  int get _secondsLeft {
    final ms = widget.expiresAt.difference(widget.clock.now()).inMilliseconds;
    return ms <= 0 ? 0 : (ms + 999) ~/ 1000;
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    setState(() {});
    if (_secondsLeft == 0 && !_fired) {
      _fired = true;
      _timer?.cancel();
      widget.onExpired();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final left = _secondsLeft;
    final mm = (left ~/ 60).toString().padLeft(2, '0');
    final ss = (left % 60).toString().padLeft(2, '0');
    final locale = Localizations.localeOf(context);
    return Text(
      [
        l10n.timeLeft(context.digits('$mm:$ss')),
        l10n.cashInExpires(BhDates.time(widget.expiresAt, locale)),
      ].join(' · '),
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: p.mutedText),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.text,
    required this.fill,
    required this.ink,
    required this.icon,
    super.key,
  });

  final String text;
  final Color fill;
  final Color ink;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      color: fill,
      padding: const EdgeInsets.all(BhSpace.m),
      child: Row(
        children: [
          Icon(icon, color: ink),
          const SizedBox(width: BhSpace.s),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: ink),
            ),
          ),
        ],
      ),
    ),
  );
}

/// A 168 dp square of 21 x 21 cells drawn from the SHA-256 of [code], with
/// three corner squares. Decorative only; never a real QR code. The bits
/// are hashed once per code and kept in the state.
class CodeGrid extends StatefulWidget {
  const CodeGrid({required this.code, required this.color, super.key});

  final String code;
  final Color color;

  static const size = 168.0;
  static const cells = 21;

  /// The cell bits, row-major: SHA-256 chained until there are enough.
  static List<bool> bitsFor(String code) {
    final bits = <bool>[];
    List<int> seed = utf8.encode(code);
    while (bits.length < cells * cells) {
      final digest = sha256.convert(seed).bytes;
      for (final b in digest) {
        for (var i = 7; i >= 0; i--) {
          bits.add((b >> i) & 1 == 1);
        }
      }
      seed = digest;
    }
    return bits.sublist(0, cells * cells);
  }

  @override
  State<CodeGrid> createState() => _CodeGridState();
}

class _CodeGridState extends State<CodeGrid> {
  late List<bool> _bits = CodeGrid.bitsFor(widget.code);

  @override
  void didUpdateWidget(CodeGrid old) {
    super.didUpdateWidget(old);
    if (old.code != widget.code) _bits = CodeGrid.bitsFor(widget.code);
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      key: const Key('cashin_grid'),
      dimension: CodeGrid.size,
      child: CustomPaint(
        painter: _GridPainter(widget.code, _bits, widget.color),
      ),
    ),
  );
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.code, this.bits, this.color);

  final String code;
  final List<bool> bits;
  final Color color;

  static bool _finder(int r, int c) {
    const n = CodeGrid.cells;
    bool inBox(int r0, int c0) =>
        r >= r0 && r < r0 + 7 && c >= c0 && c < c0 + 7;
    return inBox(0, 0) || inBox(0, n - 7) || inBox(n - 7, 0);
  }

  static bool _finderInk(int r, int c) {
    const n = CodeGrid.cells;
    final rr = r >= n - 7 ? r - (n - 7) : r;
    final cc = c >= n - 7 ? c - (n - 7) : c;
    final edge = rr == 0 || rr == 6 || cc == 0 || cc == 6;
    final core = rr >= 2 && rr <= 4 && cc >= 2 && cc <= 4;
    return edge || core;
  }

  @override
  void paint(Canvas canvas, Size size) {
    const n = CodeGrid.cells;
    final cell = size.width / n;
    final paint = Paint()..color = color;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        final on = _finder(r, c) ? _finderInk(r, c) : bits[r * n + c];
        if (on) {
          canvas.drawRect(Rect.fromLTWH(c * cell, r * cell, cell, cell), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.color != color || old.code != code;
}
