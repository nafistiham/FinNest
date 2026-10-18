import 'dart:typed_data';

import 'package:bhorosha/data/api/api_failure.dart';
import 'package:bhorosha/data/api/fake_risk_api.dart';
import 'package:bhorosha/data/api/risk_api.dart';
import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/firebase/firebase_bootstrap.dart';
import 'package:bhorosha/data/providers.dart';
import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_gemini_service.dart';
import 'package:bhorosha/features/apa/logic/apa_helpline.dart';
import 'package:bhorosha/features/apa/logic/apa_insights.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/apa/logic/apa_live_service.dart';
import 'package:bhorosha/features/apa/logic/apa_mic.dart';
import 'package:bhorosha/features/apa/logic/apa_text_service.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';
import 'package:bhorosha/features/apa/voice/fna_providers.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:bhorosha/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'apa_test_doubles.dart';

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

  group('ApaController.openFor', () {
    test(
      'held: first turn is exactly the joined reasons and it is spoken',
      () async {
        final h = ApaHarness();
        final c = containerFor(h);
        final controller = c.read(apaControllerProvider.notifier);

        await controller.openFor(held: heldScore, screen: 'result');

        final state = c.read(apaControllerProvider);
        expect(state.turns, hasLength(1));
        final first = state.turns.first;
        expect(first.speaker, ApaTurn.apa);
        expect(first.path, ApaTurn.held);
        expect(first.textBn, heldFirstLineBn);
        expect(first.textEn, heldFirstLineEn);
        expect(h.audio.spoken, [heldFirstLineBn]);
        expect(
          h.api.calls,
          isEmpty,
          reason: 'the held line never hits the network',
        );
      },
    );

    test('held with no reasons adds nothing and speaks nothing', () async {
      final h = ApaHarness();
      final c = containerFor(h);
      await c
          .read(apaControllerProvider.notifier)
          .openFor(held: FakeRiskApi.allowScore, screen: 'result');
      expect(c.read(apaControllerProvider).turns, isEmpty);
      expect(h.audio.spoken, isEmpty);
    });

    test(
      'without held adds nothing and resets a previous transcript',
      () async {
        final h = ApaHarness();
        final c = containerFor(h);
        final controller = c.read(apaControllerProvider.notifier);
        await controller.openFor(held: heldScore, screen: 'result');
        await controller.sendText('কী হলো?');
        expect(c.read(apaControllerProvider).turns, hasLength(3));

        await controller.openFor(screen: 'home');

        expect(c.read(apaControllerProvider).turns, isEmpty);
        expect(h.audio.spoken, hasLength(2), reason: 'nothing new spoken');
      },
    );

    test(
      'path is text and live unavailable with DisabledApaLiveService',
      () async {
        final h = ApaHarness();
        final c = containerFor(h);
        await c.read(apaControllerProvider.notifier).openFor(screen: 'home');
        final s = c.read(apaControllerProvider);
        expect(s.liveAvailable, isFalse);
        expect(s.path, ApaTurn.guide);
        expect(s.error, isNull);
      },
    );

    test('path is live when the Live service is available', () async {
      final h = ApaHarness(live: FakeApaLiveService());
      final c = containerFor(h);
      await c.read(apaControllerProvider.notifier).openFor(screen: 'home');
      final s = c.read(apaControllerProvider);
      expect(s.liveAvailable, isTrue);
      expect(s.path, ApaTurn.live);
    });
  });

  group('ApaController.sendText', () {
    test(
      'offline: the guide answers, it is spoken, nothing hits the network',
      () async {
        final h = ApaHarness();
        final c = containerFor(h);
        final controller = c.read(apaControllerProvider.notifier);
        await controller.openFor(held: heldScore, screen: 'result');

        await controller.sendText('  কেউ ফোনে ওটিপি চাইছে  ');

        final s = c.read(apaControllerProvider);
        expect(s.turns, hasLength(3));
        expect(s.turns[1].speaker, ApaTurn.user);
        expect(s.turns[1].textBn, 'কেউ ফোনে ওটিপি চাইছে');
        expect(s.turns[2].path, ApaTurn.guide);
        expect(s.turns[2].textBn, bn.apaCoachCode(ApaHelpline.bn));
        expect(s.turns[2].action, ApaAction.openApaScamCheck);
        expect(s.path, ApaTurn.guide);
        expect(h.audio.spoken.last, bn.apaCoachCode(ApaHelpline.bn));
        expect(h.api.calls, isEmpty, reason: 'never the server stub');
        expect(s.busy, isFalse);
      },
    );

    test(
      'Gemini when Firebase is configured: path gemini, context sent',
      () async {
        final prompts = <String>[];
        final h = ApaHarness();
        final c = containerFor(
          h,
          extra: [
            firebaseStatusProvider.overrideWithValue(FirebaseStatus.configured),
            apaGeminiGeneratorProvider.overrideWithValue(({
              required model,
              required systemInstruction,
              required prompt,
            }) async {
              prompts.add(prompt);
              return 'আপনার একটি লেনদেন আটকে আছে।';
            }),
          ],
        );
        c.read(lastScoreProvider.notifier).state = heldScore;
        final controller = c.read(apaControllerProvider.notifier);
        await controller.openFor(screen: 'home');
        expect(c.read(apaControllerProvider).path, ApaTurn.gemini);

        await controller.sendText('আমার টাকা কোথায়?');

        final s = c.read(apaControllerProvider);
        expect(s.turns.last.path, ApaTurn.gemini);
        expect(s.turns.last.textBn, 'আপনার একটি লেনদেন আটকে আছে।');
        expect(s.path, ApaTurn.gemini);
        expect(prompts.single, contains('"decision":"hold"'));
        expect(prompts.single, contains(heldScore.reasons.first.textBn));
        expect(h.api.calls, isEmpty);
      },
    );

    test(
      'a failing Gemini falls back to the offline guide, chip follows',
      () async {
        final h = ApaHarness();
        final c = containerFor(
          h,
          extra: [
            firebaseStatusProvider.overrideWithValue(FirebaseStatus.configured),
            apaGeminiGeneratorProvider.overrideWithValue(
              ({required model, required systemInstruction, required prompt}) =>
                  Future<String?>.error(StateError('no app')),
            ),
          ],
        );
        final controller = c.read(apaControllerProvider.notifier);
        await controller.openFor(screen: 'home');
        await controller.sendText('হ্যালো');
        final s = c.read(apaControllerProvider);
        expect(s.turns.last.path, ApaTurn.guide);
        expect(s.turns.last.textBn, bn.apaCoachGeneric);
        expect(s.path, ApaTurn.guide);
        expect(s.error, isNull);
      },
    );

    test('a code-like number is masked and never sent', () async {
      final prompts = <String>[];
      final h = ApaHarness();
      final c = containerFor(
        h,
        extra: [
          firebaseStatusProvider.overrideWithValue(FirebaseStatus.configured),
          apaGeminiGeneratorProvider.overrideWithValue(({
            required model,
            required systemInstruction,
            required prompt,
          }) async {
            prompts.add(prompt);
            return 'x';
          }),
        ],
      );
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');
      await controller.sendText('আমার কোড ৪৮২৯১৩');
      final turns = c.read(apaControllerProvider).turns;
      expect(turns.first.textBn, 'আমার কোড ••••');
      expect(turns.last.textBn, bn.apaSecretRedacted);
      expect(prompts, isEmpty);
      expect(h.api.calls, isEmpty);
    });

    test('ignores blank input', () async {
      final h = ApaHarness();
      final c = containerFor(h);
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');
      await controller.sendText('   ');
      expect(c.read(apaControllerProvider).turns, isEmpty);
      expect(h.api.calls, isEmpty);
    });

    test('every path failing sets the hint, keeps the user turn', () async {
      final h = ApaHarness();
      final c = containerFor(
        h,
        extra: [apaTextServiceProvider.overrideWithValue(_FailingService())],
      );
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');

      await controller.sendText('কী হলো?');

      final s = c.read(apaControllerProvider);
      expect(s.error, ApaHint.textFailed);
      expect(s.turns, hasLength(1));
      expect(s.turns.single.speaker, ApaTurn.user);
      expect(s.busy, isFalse);
      expect(h.audio.spoken, isEmpty);

      controller.dismissError();
      expect(c.read(apaControllerProvider).error, isNull);
    });
  });

  group('ApaController quick actions', () {
    test(
      'phone safe without a check says so, offers the safety screen',
      () async {
        final h = ApaHarness();
        final c = containerFor(h);
        final controller = c.read(apaControllerProvider.notifier);
        await controller.openFor(screen: 'home');
        await controller.askPhoneSafe();
        final turns = c.read(apaControllerProvider).turns;
        expect(turns.first.textBn, bn.apaQuickPhoneSafe);
        expect(turns.last.textBn, bn.apaAnswerPhoneUnchecked);
        expect(turns.last.action, ApaAction.openSafety);
      },
    );

    test(
      'why held: the first Apa line is exactly the joined reasons',
      () async {
        final h = ApaHarness();
        final c = containerFor(h);
        c.read(lastScoreProvider.notifier).state = heldScore;
        final controller = c.read(apaControllerProvider.notifier);
        await controller.openFor(screen: 'home');
        await controller.askWhyHeld();
        final turns = c.read(apaControllerProvider).turns;
        expect(turns[1].path, ApaTurn.held);
        expect(
          turns[1].textBn,
          heldScore.reasons.map((r) => r.textBn).join(' '),
        );
        expect(turns[2].textBn, bn.apaAnswerHeldNext);
      },
    );

    test('why held with nothing held explains what would hold one', () async {
      final h = ApaHarness();
      final c = containerFor(h);
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');
      await controller.askWhyHeld();
      final turns = c.read(apaControllerProvider).turns;
      expect(turns[1].textBn, bn.apaAnswerNothingHeld);
      expect(turns[2].textBn, contains('২৪ ঘণ্টায়'));
    });

    test('rules: one bubble per rule, Bangla and English', () async {
      final h = ApaHarness();
      final c = containerFor(h);
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');
      await controller.showRules();
      final turns = c.read(apaControllerProvider).turns;
      expect(turns, hasLength(1 + 5));
      expect(turns[1].textBn, startsWith('১. কোড বা পিন কাউকে বলবেন না'));
      expect(
        turns[1].textEn,
        startsWith('1. Never tell anyone your code or PIN'),
      );
    });

    test(
      'scam check posts the caller turn, quotes the evidence, stores it',
      () async {
        final h = ApaHarness();
        h.api.scamTurnResponse = scamResponse;
        final c = containerFor(h);
        final controller = c.read(apaControllerProvider.notifier);
        await controller.openFor(screen: 'home');

        await controller.startScamCheck();
        expect(c.read(apaControllerProvider).scamCheck, isTrue);
        expect(
          c.read(apaControllerProvider).turns.last.textBn,
          bn.apaScamPrompt,
        );

        await controller.sendText(
          'আপনার অ্যাকাউন্ট বন্ধ হয়ে যাবে, এখনই কোডটা বলুন',
        );

        final call = h.api.callsTo(RiskRoutes.scamTurn).single;
        final body = call.body as Map<String, dynamic>;
        expect(body['pending_action'], 'send_money');
        expect(body['session_id'], isA<String>());
        final turns = body['turns'] as List<dynamic>;
        expect(turns, hasLength(1));
        expect((turns.single as Map)['speaker'], 'caller');
        expect(
          (turns.single as Map)['text'],
          'আপনার অ্যাকাউন্ট বন্ধ হয়ে যাবে, এখনই কোডটা বলুন',
        );
        expect((turns.single as Map)['ts'], isA<double>());

        final s = c.read(apaControllerProvider);
        expect(s.scamCheck, isFalse);
        final reply = s.turns.last;
        expect(reply.textBn, contains('“${scamResponse.evidenceQuote}”'));
        expect(reply.textBn, contains(bn.apaScamTypeFakeCare));
        expect(reply.textBn, contains(bn.apaSecretOtp));
        expect(reply.textBn, contains(bn.apaScamDoHangUp));
        expect(reply.textBn, contains(bn.apaScamHotline(ApaHelpline.bn)));
        expect(reply.textEn, contains('“${scamResponse.evidenceQuote}”'));
        expect(reply.tone, ApaSeverity.danger);
        expect(reply.action, ApaAction.callHelpline);
        expect(c.read(lastEvidenceQuoteProvider), scamResponse.evidenceQuote);
      },
    );

    test('a benign scam check stores nothing', () async {
      final h = ApaHarness();
      final c = containerFor(h);
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');
      await controller.startScamCheck();
      await controller.sendText('আপনার পার্সেল এসেছে');
      expect(c.read(lastEvidenceQuoteProvider), isNull);
      expect(
        c.read(apaControllerProvider).turns.last.textBn,
        contains(bn.apaScamTypeBenign),
      );
    });

    test(
      'a failed scam check keeps the standing rule and the hotline',
      () async {
        final h = ApaHarness();
        h.api.failures[RiskRoutes.scamTurn] = const TimeoutFailure();
        final c = containerFor(h);
        final controller = c.read(apaControllerProvider.notifier);
        await controller.openFor(screen: 'home');
        await controller.startScamCheck();
        await controller.sendText('কোড বলুন');
        final last = c.read(apaControllerProvider).turns.last;
        expect(last.textBn, contains(bn.apaScamFailed));
        expect(last.action, ApaAction.callHelpline);
        expect(c.read(lastEvidenceQuoteProvider), isNull);
      },
    );

    test('openFor with an insight: it is the first bubble', () async {
      final h = ApaHarness();
      final c = containerFor(h);
      final insight = c.read(apaInsightsProvider).first;
      await c
          .read(apaControllerProvider.notifier)
          .openFor(screen: 'home', insight: insight);
      final first = c.read(apaControllerProvider).turns.first;
      expect(first.textBn, '${insight.titleBn}\n${insight.bodyBn}');
      expect(first.action, insight.action);
    });

    test('held + the held insight: the reasons line once, first', () async {
      final h = ApaHarness();
      final c = containerFor(h);
      c.read(lastScoreProvider.notifier).state = heldScore;
      final insight = c.read(apaInsightsProvider).first;
      expect(insight.id, 'held_transfer');
      await c
          .read(apaControllerProvider.notifier)
          .openFor(held: heldScore, screen: 'home', insight: insight);
      final turns = c.read(apaControllerProvider).turns;
      expect(turns, hasLength(1));
      expect(turns.single.textBn, heldFirstLineBn);
    });
  });

  group('ApaController hold-to-talk', () {
    test(
      'live unavailable: holdStart sets the text-path hint and stays on text',
      () async {
        final h = ApaHarness();
        final c = containerFor(h);
        final controller = c.read(apaControllerProvider.notifier);
        await controller.openFor(screen: 'home');

        await controller.holdStart();

        final s = c.read(apaControllerProvider);
        expect(s.listening, isFalse);
        expect(s.path, ApaTurn.guide);
        expect(s.error, ApaHint.liveUnavailable);
        expect(h.mic.permissionRequests, 0);
        expect(h.mic.starts, 0);
      },
    );

    test('mic denied: hint and text path, no session', () async {
      final live = FakeApaLiveService();
      final h = ApaHarness(live: live, mic: FakeApaMic(granted: false));
      final c = containerFor(h);
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');

      await controller.holdStart();

      final s = c.read(apaControllerProvider);
      expect(s.error, ApaHint.micDenied);
      expect(s.path, ApaTurn.guide);
      expect(s.listening, isFalse);
      expect(live.starts, 0);
    });

    test(
      'live: start → mic chunks forwarded → endTurn → transcript and audio',
      () async {
        final live = FakeApaLiveService();
        final h = ApaHarness(live: live);
        final c = containerFor(h);
        final controller = c.read(apaControllerProvider.notifier);
        await controller.openFor(held: heldScore, screen: 'result');

        await controller.holdStart();
        expect(c.read(apaControllerProvider).listening, isTrue);
        expect(live.starts, 1);
        expect(
          live.startedWith,
          const ApaContext(lastRisk: 0.91, screen: 'result'),
        );
        expect(h.mic.starts, 1);

        h.mic.emit(Uint8List.fromList([1, 2, 3, 4]));
        await Future<void>.delayed(Duration.zero);
        expect(live.chunks, hasLength(1));

        await controller.holdEnd();
        expect(live.endTurns, 1);
        expect(h.mic.stops, greaterThanOrEqualTo(1));
        var s = c.read(apaControllerProvider);
        expect(s.listening, isFalse);
        expect(s.speaking, isTrue);

        live.pushAudio(Uint8List.fromList([9, 9]));
        expect(h.native.pcmChunks, hasLength(1));
        expect(h.native.pcmSampleRates.single, 24000);

        live.pushTranscript('টাকা ');
        live.pushTranscript('নিরাপদ আছে।');
        s = c.read(apaControllerProvider);
        expect(s.turns.last.speaker, ApaTurn.apa);
        expect(s.turns.last.path, ApaTurn.live);
        expect(s.turns.last.textBn, 'টাকা নিরাপদ আছে।');

        live.pushTurnComplete();
        expect(c.read(apaControllerProvider).speaking, isFalse);

        // A second hold reuses the session.
        await controller.holdStart();
        expect(live.starts, 1);
        await controller.holdEnd();
        expect(live.endTurns, 2);

        await controller.close();
        expect(live.stops, 1);
      },
    );

    test(
      'finger lifted during the permission prompt: mic never opens',
      () async {
        final live = FakeApaLiveService();
        final mic = GatedApaMic();
        final h = ApaHarness(live: live, mic: mic);
        final c = containerFor(h);
        final controller = c.read(apaControllerProvider.notifier);
        await controller.openFor(screen: 'home');

        final start = controller.holdStart();
        await Future<void>.delayed(Duration.zero);
        await controller.holdEnd(); // precedes holdStart's completion
        mic.permission.complete(true);
        mic.started.complete();
        await start;

        expect(mic.starts, 0);
        expect(c.read(apaControllerProvider).listening, isFalse);
        expect(live.endTurns, 0);
      },
    );

    test('finger lifted while the mic is starting: mic is stopped', () async {
      final live = FakeApaLiveService();
      final mic = GatedApaMic()..permission.complete(true);
      final h = ApaHarness(live: live, mic: mic);
      final c = containerFor(h);
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');
      final stopsBefore = mic.stops;

      final start = controller.holdStart();
      await Future<void>.delayed(Duration.zero);
      expect(mic.starts, 1);
      await controller.holdEnd();
      mic.started.complete();
      await start;

      expect(mic.stops, stopsBefore + 1, reason: 'the mic is closed again');
      expect(c.read(apaControllerProvider).listening, isFalse);
      mic.emit(Uint8List.fromList([1, 2]));
      await Future<void>.delayed(Duration.zero);
      expect(live.chunks, isEmpty);
    });

    test('live error mid-session falls back to text with a hint', () async {
      final live = FakeApaLiveService();
      final h = ApaHarness(live: live);
      final c = containerFor(h);
      final controller = c.read(apaControllerProvider.notifier);
      await controller.openFor(screen: 'home');
      await controller.holdStart();

      live.pushError(StateError('socket closed'));
      await Future<void>.delayed(Duration.zero);

      final s = c.read(apaControllerProvider);
      expect(s.listening, isFalse);
      expect(s.path, ApaTurn.guide);
      expect(s.error, ApaHint.liveFailed);
      expect(live.stops, 1);
    });
  });

  group('providers', () {
    test(
      'apaLiveServiceProvider is Disabled unless Firebase is configured',
      () {
        final absent = ProviderContainer();
        addTearDown(absent.dispose);
        expect(
          absent.read(apaLiveServiceProvider),
          isA<DisabledApaLiveService>(),
        );

        final failed = ProviderContainer(
          overrides: [
            firebaseStatusProvider.overrideWithValue(FirebaseStatus.failed),
          ],
        );
        addTearDown(failed.dispose);
        expect(
          failed.read(apaLiveServiceProvider),
          isA<DisabledApaLiveService>(),
        );

        final configured = ProviderContainer(
          overrides: [
            firebaseStatusProvider.overrideWithValue(FirebaseStatus.configured),
          ],
        );
        addTearDown(configured.dispose);
        expect(
          configured.read(apaLiveServiceProvider),
          isA<FirebaseApaLiveService>(),
        );
      },
    );

    test('text service: offline guide first, Gemini only when configured', () {
      final h = ApaHarness();
      final c = containerFor(h);
      expect(c.read(apaUserIdProvider), 'demo');
      final offline = c.read(apaTextServiceProvider);
      expect(offline, isA<FallbackApaService>());
      expect(
        (offline as FallbackApaService).primary,
        isA<RuleBasedApaService>(),
      );
      expect(offline.secondary, isA<ApaTextService>());

      final configured = containerFor(
        h,
        extra: [
          firebaseStatusProvider.overrideWithValue(FirebaseStatus.configured),
        ],
      );
      expect(configured.read(apaTextServiceProvider), isA<GeminiApaService>());
    });
  });
}

final bn = lookupAppLocalizations(const Locale('bn'));

class _FailingService implements ApaService {
  @override
  Future<List<ApaTurn>> ask(String t, ApaContext c, ApaContextSnapshot s) =>
      Future.error(StateError('down'));
}
