import 'package:bhorosha/core/clock.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/providers.dart';
import 'package:bhorosha/data/native/bhorosha_native.dart';
import 'package:bhorosha/data/native/fake_native.dart';
import 'package:bhorosha/features/send_money/logic/risk_flow.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;
  late FakeClock clock;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 10, 16, 12));
    container = ProviderContainer(
      overrides: [
        riskApiProvider.overrideWithValue(FakeRiskApi()),
        nativeProvider.overrideWithValue(FakeBhoroshaNative()),
        clockProvider.overrideWithValue(clock),
      ],
    );
  });

  tearDown(() => container.dispose());

  test('riskFlowProvider wires the cooldown, clock and evidence quote', () {
    final flow = container.read(riskFlowProvider);
    expect(flow, isA<RiskFlow>());
    expect(flow.cooldown, same(container.read(cooldownProvider)));
    expect(flow.clock, same(clock));
    expect(flow.nonce(), isNot(flow.nonce()));
  });

  test('cooldownProvider is a singleton per container', () {
    expect(
      container.read(cooldownProvider),
      same(container.read(cooldownProvider)),
    );
  });

  test('lastScore and lastEvidenceQuote start empty and are writable', () {
    expect(container.read(lastScoreProvider), isNull);
    expect(container.read(lastEvidenceQuoteProvider), isNull);
    container.read(lastScoreProvider.notifier).state = FakeRiskApi.allowScore;
    container.read(lastEvidenceQuoteProvider.notifier).state = 'ওটিপি বলুন';
    expect(container.read(lastScoreProvider), FakeRiskApi.allowScore);
    expect(container.read(lastEvidenceQuoteProvider), 'ওটিপি বলুন');
  });

  test('RiskSession.reset clears cooldown, last score and evidence quote', () {
    container.read(cooldownProvider).arm('call_active', 300);
    container.read(lastScoreProvider.notifier).state = FakeRiskApi.allowScore;
    container.read(lastEvidenceQuoteProvider.notifier).state = 'কোড';
    expect(container.read(riskSessionProvider), 0);

    container.read(riskSessionProvider.notifier).reset();

    expect(container.read(cooldownProvider).shouldSpeak('call_active'), isTrue);
    expect(container.read(lastScoreProvider), isNull);
    expect(container.read(lastEvidenceQuoteProvider), isNull);
    expect(container.read(riskSessionProvider), 1);
  });

  test('resetRiskSession works from a provider Ref too', () {
    final probe = Provider<void>((ref) {
      ref.read(cooldownProvider).arm('sim_swap', 300);
      resetRiskSession(ref);
    });
    container.read(probe);
    expect(container.read(cooldownProvider).shouldSpeak('sim_swap'), isTrue);
  });
}
