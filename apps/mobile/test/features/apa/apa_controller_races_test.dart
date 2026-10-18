// Lifecycle races of the FNA controller: a late text
// reply never lands in the next sheet session, a second hold during the Live
// connect never opens a second session or microphone, and one controller
// hosts one modal sheet at a time.

import 'dart:async';
import 'dart:typed_data';

import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_text_service.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';
import 'package:bhorosha/features/apa/voice/fna_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'apa_test_doubles.dart';

/// Answers only when the test completes [reply].
class SlowService implements ApaService {
  final Completer<List<ApaTurn>> reply = Completer<List<ApaTurn>>();
  int asks = 0;

  @override
  Future<List<ApaTurn>> ask(String t, ApaContext c, ApaContextSnapshot s) {
    asks++;
    return reply.future;
  }
}

Future<void> microtasks() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer containerFor(
    ApaHarness h, {
    List<Override> extra = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        ...h.overrides,
        // These tests pin the original sheet (FNA_VOICE_AGENT off).
        fnaVoiceAgentEnabledProvider.overrideWithValue(false),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('M4: a late text reply', () {
    test('after close is dropped: nothing appended, nothing spoken', () async {
      final h = ApaHarness();
      final slow = SlowService();
      final c = containerFor(
        h,
        extra: [apaTextServiceProvider.overrideWithValue(slow)],
      );
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');

      final send = controller.sendText('কী হলো?');
      await microtasks();
      expect(c.read(apaControllerProvider).busy, isTrue);
      await controller.close();

      slow.reply.complete([
        const ApaTurn(
          speaker: ApaTurn.apa,
          textBn: 'দেরি',
          path: ApaTurn.guide,
        ),
      ]);
      await send;

      final s = c.read(apaControllerProvider);
      expect(s.turns.map((t) => t.textBn), isNot(contains('দেরি')));
      expect(h.audio.spoken, isEmpty);
    });

    test('after openFor never lands in the next session', () async {
      final h = ApaHarness();
      final slow = SlowService();
      final c = containerFor(
        h,
        extra: [apaTextServiceProvider.overrideWithValue(slow)],
      );
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');
      final send = controller.sendText('কী হলো?');
      await microtasks();

      await controller.close();
      await controller.openFor(held: heldScore, screen: 'result');
      slow.reply.complete([
        const ApaTurn(
          speaker: ApaTurn.apa,
          textBn: 'দেরি',
          path: ApaTurn.guide,
        ),
      ]);
      await send;

      final s = c.read(apaControllerProvider);
      expect(s.turns, hasLength(1), reason: 'only the new held line');
      expect(s.turns.single.path, ApaTurn.held);
      expect(s.busy, isFalse);
      expect(h.audio.spoken, [heldFirstLineBn], reason: 'late line not spoken');
    });

    test('a late failure never shows the hint in the next session', () async {
      final h = ApaHarness();
      final slow = SlowService();
      final c = containerFor(
        h,
        extra: [apaTextServiceProvider.overrideWithValue(slow)],
      );
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');
      final send = controller.sendText('কী হলো?');
      await microtasks();
      await controller.close();
      await controller.openFor(screen: 'home');
      slow.reply.completeError(StateError('down'));
      await send;
      expect(c.read(apaControllerProvider).error, isNull);
    });

    test('a late scam-check reply is dropped too', () async {
      final h = ApaHarness();
      h.api.scamTurnResponse = scamResponse;
      final release = h.api.hold(RiskRoutes.scamTurn);
      final c = containerFor(h);
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');
      await controller.startScamCheck();
      final send = controller.sendText('কোডটা বলুন');
      await microtasks();

      await controller.close();
      await controller.openFor(screen: 'home');
      release();
      await send;

      final s = c.read(apaControllerProvider);
      expect(s.turns, isEmpty);
      expect(s.busy, isFalse);
    });
  });

  group('M5: hold-to-talk pressed again during the Live connect', () {
    test('one session, one microphone, one subscription', () async {
      final live = GatedApaLiveService();
      final h = ApaHarness(live: live);
      final c = containerFor(h);
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');

      final first = controller.holdStart();
      await microtasks();
      expect(live.starts, 1);
      final second = controller.holdStart();
      await microtasks();
      expect(live.starts, 1, reason: 'the second hold awaits the connect');
      expect(h.mic.starts, 0);

      live.connect.complete();
      await first;
      await second;

      expect(live.starts, 1);
      expect(h.mic.starts, 1, reason: 'the microphone opened once');
      expect(c.read(apaControllerProvider).listening, isTrue);

      // One subscription: each chunk is forwarded once.
      h.mic.emit(Uint8List.fromList([1, 2, 3]));
      await microtasks();
      expect(live.chunks, hasLength(1));

      await controller.holdEnd();
      expect(h.mic.stops, greaterThanOrEqualTo(1));
      expect(live.endTurns, 1);
    });

    test('released during the connect: the mic never opens', () async {
      final live = GatedApaLiveService();
      final h = ApaHarness(live: live);
      final c = containerFor(h);
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');

      final first = controller.holdStart();
      await microtasks();
      await controller.holdEnd();
      live.connect.complete();
      await first;

      expect(h.mic.starts, 0);
      expect(c.read(apaControllerProvider).listening, isFalse);
      // The session is kept for the next hold.
      await controller.holdStart();
      expect(live.starts, 1);
      expect(h.mic.starts, 1);
    });
  });

  group('M6: one sheet per controller', () {
    test('markSheetOpen claims the slot once until markSheetClosed', () {
      final h = ApaHarness();
      final c = containerFor(h);
      final controller = c.read(apaControllerProvider.notifier);
      expect(controller.sheetOpen, isFalse);
      expect(controller.markSheetOpen(), isTrue);
      expect(controller.markSheetOpen(), isFalse);
      expect(controller.sheetOpen, isTrue);
      controller.markSheetClosed();
      expect(controller.markSheetOpen(), isTrue);
    });
  });
}
