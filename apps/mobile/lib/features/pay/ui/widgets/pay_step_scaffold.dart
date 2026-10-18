import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/theme/theme.dart';
import '../../../../app/widgets/step_progress.dart';
import '../../logic/pay_paths.dart';

/// Step 1 chrome shared by cash out, recharge and pay bill: app bar (back
/// goes Home), the step bar, and either the list or the inline number panel
/// (cross-fade + rise over `normal`). System back closes an open panel
/// first, then goes Home.
class PayStepScaffold extends StatelessWidget {
  const PayStepScaffold({
    required this.title,
    required this.step,
    required this.total,
    required this.list,
    required this.bottomBar,
    this.panel,
    this.onClosePanel,
    super.key,
  });

  final String title;
  final int step;
  final int total;
  final Widget list;

  /// Non-null while the number panel is open.
  final Widget? panel;
  final VoidCallback? onClosePanel;
  final Widget bottomBar;

  @override
  Widget build(BuildContext context) {
    final motion = BhMotion.of(context);
    final open = panel != null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (open) {
          onClosePanel?.call();
        } else {
          context.go(PayPaths.home);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: BackButton(onPressed: () => context.go(PayPaths.home)),
        ),
        bottomNavigationBar: bottomBar,
        body: Column(
          children: [
            StepProgress(step: step, total: total),
            Expanded(
              child: AnimatedSwitcher(
                duration: motion.normal,
                switchInCurve: BhCurves.enter,
                switchOutCurve: BhCurves.exit,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.08),
                      end: Offset.zero,
                    ).animate(a),
                    child: child,
                  ),
                ),
                child: open
                    ? KeyedSubtree(key: const ValueKey('panel'), child: panel!)
                    : KeyedSubtree(key: const ValueKey('list'), child: list),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A muted helper line with a leading icon (2.1 helper, 9.3 agent line).
class PayHelperLine extends StatelessWidget {
  const PayHelperLine(this.text, {this.icon = Icons.info_outline, super.key});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BhSpace.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 20, color: p.mutedText),
          ),
          const SizedBox(width: BhSpace.s),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: p.mutedText),
            ),
          ),
        ],
      ),
    );
  }
}
