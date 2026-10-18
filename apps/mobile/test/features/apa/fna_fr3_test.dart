// FR-3: no hold reason text reaches a model. Every
// payload the chat agent's model and the Live session receive is checked
// while a payment is held with known reasons, including tool results.

import 'package:bhorosha/features/apa/logic/apa_controller.dart';
import 'package:bhorosha/features/apa/logic/apa_insights_provider.dart';
import 'package:bhorosha/features/apa/logic/apa_turn.dart';
import 'package:bhorosha/features/apa/voice/fna_live_transport.dart';
import 'package:bhorosha/features/apa/voice/fna_model_context.dart';
import 'package:bhorosha/features/apa/voice/fna_text_agent.dart';
import 'package:bhorosha/features/apa/voice/fna_tools.dart';
import 'package:bhorosha/features/apa/voice/fna_voice_session.dart';
import 'package:bhorosha/features/send_money/logic/risk_providers.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apa_test_doubles.dart';
import 'fna_logic_fakes.dart';
import 'voice/fna_live_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final reasons = [
    for (final r in heldScore.reasons) ...[r.textBn, r.textEn],
  ];

  test('chat: instruction, messages, history and tool results carry no '
      'reason text', () async {
    final toolResults = <Object?>[];
    final chat = ScriptedChat(
      answer: (r) async {
        for (final name in [
          FnaToolNames.status,
          FnaToolNames.holdReason,
          FnaToolNames.callSummary,
        ]) {
          final tool = r.tools.firstWhere((t) => t.name == name);
          toolResults.add(await tool.callable(const {}));
        }
        final search = r.tools.firstWhere((t) => t.name == FnaToolNames.search);
        toolResults.add(await search.callable({'query': 'held টাকা আটকে'}));
        return 'এটাই ফিননেস্টের দেওয়া কারণ।';
      },
    );
    final h = FnaLogicHarness(chat: chat);
    final c = h.container();
    c.read(lastScoreProvider.notifier).state = heldScore;
    final ctrl = c.read(apaControllerProvider.notifier);
    await ctrl.openFor(held: heldScore, screen: 'result');
    await ctrl.sendText('আমার ফোন কি নিরাপদ?');
    await ctrl.sendText('আমার টাকার কী অবস্থা?');
    await ctrl.showRules();

    expect(chat.requests, hasLength(3));
    for (final FnaChatRequest r in chat.requests) {
      expect(containsAnyReasonText(r.systemInstruction, reasons), isFalse);
      expect(containsAnyReasonText(r.message.toJson(), reasons), isFalse);
      expect(
        containsAnyReasonText([for (final h in r.history) h.toJson()], reasons),
        isFalse,
      );
    }
    expect(toolResults, isNotEmpty);
    expect(containsAnyReasonText(toolResults, reasons), isFalse);
    // The app itself showed the server text (the tool's side effect).
    final shown = c
        .read(apaControllerProvider)
        .turns
        .where((t) => t.path == ApaTurn.held);
    expect(shown, isNotEmpty);
  });

  test('voice: CONTEXT, typed text and tool responses carry no reason '
      'text', () async {
    final h = FnaLogicHarness();
    final c = h.container();
    c.read(lastScoreProvider.notifier).state = heldScore;
    final ctrl = c.read(apaControllerProvider.notifier);
    await ctrl.openFor(held: heldScore, screen: 'result');
    await ctrl.startVoice();
    await flush();
    h.live.setupComplete();
    await flush();
    expect(c.read(apaControllerProvider).voicePhase, FnaPhase.listening);

    await ctrl.sendText('টাকা কেন আটকাল?');
    h.live.emit(
      const FnaToolCalls([
        FunctionCall(FnaToolNames.status, {}, id: 's'),
        FunctionCall(FnaToolNames.holdReason, {}, id: 'h'),
        FunctionCall(FnaToolNames.callSummary, {}, id: 'f'),
        FunctionCall(FnaToolNames.search, {'query': 'held আটকে'}, id: 'q'),
      ]),
    );
    await flush();

    final live = h.live;
    expect(live.contexts, isNotEmpty);
    expect(h.contexts, isNotEmpty);
    expect(containsAnyReasonText(live.contexts, reasons), isFalse);
    expect(containsAnyReasonText(live.texts, reasons), isFalse);
    final responses = [
      for (final batch in live.toolResponses)
        for (final r in batch) r.toJson(),
    ];
    expect(responses, hasLength(4));
    expect(containsAnyReasonText(responses, reasons), isFalse);
  });

  test('the model context and the chat instruction have a held count, not '
      'the reasons', () {
    final h = FnaLogicHarness();
    final c = h.container();
    c.read(lastScoreProvider.notifier).state = heldScore;
    final snapshot = c.read(apaSnapshotProvider);
    expect(snapshot.heldReasons, isNotEmpty, reason: 'the test holds money');
    final json = fnaModelContextJson(snapshot);
    expect(json, contains('"held_count":1'));
    expect(containsAnyReasonText(json, reasons), isFalse);
    expect(
      containsAnyReasonText(fnaTextSystemInstruction(snapshot), reasons),
      isFalse,
    );
  });
}
