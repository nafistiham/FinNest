import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../app/l10n.dart';
import '../../../../app/theme/theme.dart';
import '../../../../app/widgets/bangla_numpad.dart';
import '../../../../app/widgets/number_display.dart';
import '../../../../core/haptics.dart';
import '../../logic/billers.dart';
import '../../logic/pay_rules.dart';

/// What the panel takes: a Bangladeshi mobile number or a bill account of a
/// fixed length.
enum NumberKind { phone, account }

/// The digits typed into the inline number panel. Owned
/// by the step screen so its bottom bar can read the validation; keeps the
/// typed digits for 30 s after the panel closes.
class NumberEntryController extends ChangeNotifier {
  NumberEntryController({
    this.kind = NumberKind.phone,
    int? length,
    DateTime Function()? now,
  }) : length = length ?? PayRules.phoneLength,
       _now = now ?? DateTime.now;

  final NumberKind kind;
  final int length;
  final DateTime Function() _now;

  /// How long typed digits survive a "বাতিল".
  static const keepFor = Duration(seconds: 30);

  String _digits = '';
  bool _open = false;
  DateTime? _closedAt;

  /// ASCII digits typed so far.
  String get digits => _digits;
  bool get isOpen => _open;
  bool get isComplete => _digits.length == length;

  /// Phone: incomplete / invalid / valid. Account: incomplete or valid.
  PhoneCheck get check {
    if (kind == NumberKind.phone) return PayRules.checkPhone(_digits);
    return isComplete ? PhoneCheck.valid : PhoneCheck.incomplete;
  }

  bool get isValid => check == PhoneCheck.valid;

  void open() {
    final closed = _closedAt;
    if (closed != null && _now().difference(closed) > keepFor) _digits = '';
    _open = true;
    notifyListeners();
  }

  void close() {
    _open = false;
    _closedAt = _now();
    notifyListeners();
  }

  void append(int d) {
    if (_digits.length >= length) return;
    _digits += '$d';
    notifyListeners();
  }

  void backspace() {
    if (_digits.isEmpty) return;
    _digits = _digits.substring(0, _digits.length - 1);
    notifyListeners();
  }

  void clear() {
    _digits = '';
    notifyListeners();
  }

  /// Digits only, a leading `88` dropped for phones, the first [length].
  void paste(String raw) {
    var d = kind == NumberKind.phone
        ? PayRules.normalisePhone(asciiDigits(raw))
        : asciiDigits(raw).replaceAll(RegExp(r'\D'), '');
    if (d.length > length) d = d.substring(0, length);
    _digits = d;
    notifyListeners();
  }

  /// The display form: "01712-345678" for phones, "1234 5678" for accounts.
  String get grouped => kind == NumberKind.phone
      ? PayRules.groupPhone(_digits)
      : Bill.groupAccount(_digits);
}

/// The pinned panel that replaces the step-1 list for a new number: title
/// with "বাতিল", the [NumberDisplay], an optional [note] (e.g. "এটি মা-এর
/// নম্বর") and the number numpad (`পেস্ট ০ ⌫`). The bottom bar's primary
/// (owned by the step) reads [controller].
class NumberEntryPanel extends StatelessWidget {
  const NumberEntryPanel({
    required this.controller,
    required this.title,
    required this.onCancel,
    this.note,
    this.haptics = const SystemHaptics(),
    super.key,
  });

  final NumberEntryController controller;
  final String title;
  final VoidCallback onCancel;
  final String? note;
  final Haptics haptics;

  Future<void> _paste() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final t = data?.text;
      if (t != null && t.isNotEmpty) controller.paste(t);
    } on Object {
      // No clipboard: nothing to paste.
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final l10n = context.l10n;
    return LayoutBuilder(
      builder: (context, box) {
        final compact = box.maxHeight < 480;
        // Only the display listens to the controller: a key press does not
        // rebuild the title row or the twelve keys.
        return Column(
          key: const Key('number_panel'),
          children: [
            SizedBox(
              height: BhSize.touch,
              child: Padding(
                padding: const EdgeInsets.only(left: BhSpace.m),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium,
                      ),
                    ),
                    TextButton(
                      key: const Key('number_cancel'),
                      onPressed: onCancel,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(BhSize.touch, BhSize.touch),
                        foregroundColor: p.primary,
                      ),
                      child: Text(l10n.cancel),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListenableBuilder(
                        listenable: controller,
                        builder: (context, _) => NumberDisplay.grouped(
                          grouped: controller.grouped,
                          count: controller.digits.length,
                          length: controller.length,
                          invalid: controller.check == PhoneCheck.invalid,
                        ),
                      ),
                      if (note != null)
                        Text(
                          note!,
                          key: const Key('number_note'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(color: p.success),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Numpad(
              variant: NumpadVariant.number,
              keyHeight: compact ? BhSize.keyCompact : BhSize.keyAmount,
              gap: compact ? BhSpace.xs : BhSpace.s,
              onDigit: (d) {
                unawaited(haptics.key());
                controller.append(d);
              },
              onBackspace: () {
                unawaited(haptics.key());
                controller.backspace();
              },
              onClear: controller.clear,
              onPaste: _paste,
            ),
          ],
        );
      },
    );
  }
}
