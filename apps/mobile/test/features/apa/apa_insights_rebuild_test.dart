// M24: the insight list has value semantics and is not recomputed when only
// the balance (or the name) changes, so `ApaBar`, the Home card and Home's
// listener do not rebuild on every ledger tick. Also the `pickServerText`
// fallbacks of an insight.

import 'dart:async';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/logic/apa_content.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apa_test_doubles.dart';

/// A few event-loop turns: the stream delivers, Riverpod's scheduler runs.
Future<void> settle() async {
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const a = ApaInsight(
    id: 'sim_swap',
    severity: ApaSeverity.caution,
    priority: 5,
    titleBn: 'সিম',
    titleEn: 'SIM',
    bodyBn: 'বদলেছে',
    bodyEn: '',
    action: ApaAction.callHelpline,
    actionLabelBn: 'কল',
    actionLabelEn: 'Call',
    source: ApaSource.signal,
  );

  test('ApaInsight has value equality', () {
    const b = ApaInsight(
      id: 'sim_swap',
      severity: ApaSeverity.caution,
      priority: 5,
      titleBn: 'সিম',
      titleEn: 'SIM',
      bodyBn: 'বদলেছে',
      bodyEn: '',
      action: ApaAction.callHelpline,
      actionLabelBn: 'কল',
      actionLabelEn: 'Call',
      source: ApaSource.signal,
    );
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode);
    expect(
      a,
      isNot(
        equals(
          const ApaInsight(
            id: 'sim_swap',
            severity: ApaSeverity.danger,
            priority: 5,
            titleBn: 'সিম',
            titleEn: 'SIM',
            bodyBn: 'বদলেছে',
            bodyEn: '',
          ),
        ),
      ),
    );
  });

  test('title/body/actionLabel follow pickServerText, with fallback', () {
    expect(a.title(true), 'SIM');
    expect(a.title(false), 'সিম');
    expect(a.body(true), 'বদলেছে', reason: 'empty English falls back');
    expect(a.actionLabel(true), 'Call');
  });

  test('ApaContextSnapshot: value equality and insightFacts drop name and '
      'balance', () {
    const x = ApaContextSnapshot(lastScore: heldScore, balanceBdt: 10);
    const y = ApaContextSnapshot(lastScore: heldScore, balanceBdt: 20);
    expect(x, isNot(equals(y)));
    expect(x.insightFacts, equals(y.insightFacts));
    expect(x.insightFacts.hashCode, y.insightFacts.hashCode);
    expect(x.insightFacts.balanceBdt, isNull);
    expect(x.copyWith(balanceBdt: 20), equals(y));
    expect(x.withScreen('result').screen, 'result');
    expect(x.withScreen('result').insightFacts, equals(y.insightFacts));
  });

  test(
    'a balance tick changes the snapshot but not the insight list',
    () async {
      final balance = StreamController<double?>();
      addTearDown(balance.close);
      final h = ApaHarness();
      final c = ProviderContainer(
        overrides: [
          ...h.overrides,
          apaBalanceProvider.overrideWith((_) => balance.stream),
        ],
      );
      addTearDown(c.dispose);
      c.read(lastScoreProvider.notifier).state = heldScore;
      // The guide asset load settles first: that is a real content change.
      await c.read(apaContentProvider.future);
      await settle();

      var notified = 0;
      c.listen(apaInsightsProvider, (_, _) => notified++);
      final before = c.read(apaInsightsProvider);
      expect(before.first.id, 'held_transfer');

      balance.add(9841);
      await settle();
      expect(c.read(apaSnapshotProvider).balanceBdt, 9841);
      final after = c.read(apaInsightsProvider);
      expect(identical(before, after), isTrue, reason: 'not recomputed');
      expect(notified, 0, reason: 'watchers did not rebuild');

      balance.add(4841);
      await settle();
      expect(c.read(apaSnapshotProvider).balanceBdt, 4841);
      expect(identical(before, c.read(apaInsightsProvider)), isTrue);
      expect(notified, 0);

      // A real fact change still recomputes.
      c.read(lastEvidenceQuoteProvider.notifier).state = 'কোডটা বলুন';
      await settle();
      expect(c.read(apaInsightsProvider).first.id, 'scam_call');
      expect(notified, 1);
    },
  );

  test('two blank text_en reasons never give a " " English body', () {
    const blank = ScoreResponse(
      decision: Decision.hold,
      riskScore: 0.9,
      band: Band.critical,
      reasons: [
        Reason(code: 'A', weight: 0.5, textBn: 'ক', textEn: ''),
        Reason(code: 'B', weight: 0.5, textBn: 'খ', textEn: ''),
      ],
      actions: [],
      modelVersion: 'rules-v1',
    );
    final h = ApaHarness();
    final c = ProviderContainer(overrides: h.overrides);
    addTearDown(c.dispose);
    c.read(lastScoreProvider.notifier).state = blank;
    final held = c.read(apaInsightsProvider).first;
    expect(held.bodyBn, 'ক খ');
    expect(held.bodyEn, isEmpty);
    expect(held.body(true), 'ক খ', reason: 'falls back to Bangla');
  });
}
