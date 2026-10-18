import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/persona.dart';

/// The full `demo_state/{uid}` document. Only the
/// [DemoFlags] subset ever reaches the server; the rest drives the app.
class DemoState {
  const DemoState({
    this.simSwap = false,
    this.callActive = false,
    this.screenShare = false,
    this.callerInContacts = false,
    this.persona,
    this.forcedSafetyVerdict,
    this.scamScore = 0.0,
    this.integrityScenario,
    this.inboundMuleScore = 0.0,
  });

  /// Reads the Firestore / SharedPreferences document; missing keys take
  /// the [initial] value, so an empty map is a valid document.
  factory DemoState.fromDoc(Map<String, dynamic> doc) => DemoState(
    simSwap: readBool(doc, 'sim_swap', false),
    callActive: readBool(doc, 'call_active', false),
    screenShare: readBool(doc, 'screen_share', false),
    callerInContacts: readBool(doc, 'caller_in_contacts', false),
    persona: Persona.tryParse(readStringOrNull(doc, 'persona')),
    forcedSafetyVerdict: switch (readStringOrNull(
      doc,
      'forced_safety_verdict',
    )) {
      null => null,
      final w => SafetyVerdict.fromWire(w),
    },
    scamScore: readDouble(doc, 'scam_score', 0.0),
    integrityScenario: readStringOrNull(doc, 'integrity_scenario'),
    inboundMuleScore: readDouble(doc, 'inbound_mule_score', 0.0),
  );

  static const DemoState initial = DemoState();

  final bool simSwap;
  final bool callActive;
  final bool screenShare;
  final bool callerInContacts;
  final Persona? persona;

  /// Emulator escape hatch for the safety badge; `null` means "use the server".
  final SafetyVerdict? forcedSafetyVerdict;

  /// Last `rolling_score` from the replayed scam script.
  final double scamScore;

  /// Play Integrity scenario the demo panel forces on the next app-safety
  /// call. Client-only; never part of [DemoFlags]. Values:
  /// - `null`: clean attested demo token;
  /// - `'UNKNOWN_CONTROLLING'`: screen controlled by another app;
  /// - `'UNRECOGNIZED_VERSION'`: modded app;
  /// - `'MEETS_VIRTUAL_INTEGRITY'`: emulator;
  /// - `'unbound'`: token without the request hash.
  final String? integrityScenario;

  /// `demo_flags.inbound_mule_score`: the suspect-payee story sets it above
  /// the server's hold threshold, so the live service's DEST_MULE_RISK rule
  /// fires with the payee's own evidence in the reason (the service screens the
  /// payee with the transfer; the ring's L1 account alone scores under it).
  final double inboundMuleScore;

  /// Pass [unchanged] (the default) to keep a nullable value; `null` clears it.
  DemoState copyWith({
    bool? simSwap,
    bool? callActive,
    bool? screenShare,
    bool? callerInContacts,
    Object? persona = unchanged,
    Object? forcedSafetyVerdict = unchanged,
    double? scamScore,
    Object? integrityScenario = unchanged,
    double? inboundMuleScore,
  }) => DemoState(
    simSwap: simSwap ?? this.simSwap,
    callActive: callActive ?? this.callActive,
    screenShare: screenShare ?? this.screenShare,
    callerInContacts: callerInContacts ?? this.callerInContacts,
    persona: identical(persona, unchanged) ? this.persona : persona as Persona?,
    forcedSafetyVerdict: identical(forcedSafetyVerdict, unchanged)
        ? this.forcedSafetyVerdict
        : forcedSafetyVerdict as SafetyVerdict?,
    scamScore: scamScore ?? this.scamScore,
    integrityScenario: identical(integrityScenario, unchanged)
        ? this.integrityScenario
        : integrityScenario as String?,
    inboundMuleScore: inboundMuleScore ?? this.inboundMuleScore,
  );

  /// The subset sent in `ScoreRequest.demo_flags`. The app-safety verdict
  /// comes from the badge flow (or the forced verdict) and the mule score
  /// from the server, so both are parameters.
  DemoFlags toDemoFlags({
    SafetyVerdict? appSafetyVerdict,
    double? inboundMuleScore,
  }) => DemoFlags(
    simSwap: simSwap,
    callActive: callActive,
    screenShare: screenShare,
    callerInContacts: callerInContacts,
    appSafetyVerdict:
        forcedSafetyVerdict ?? appSafetyVerdict ?? SafetyVerdict.safe,
    inboundMuleScore: inboundMuleScore ?? this.inboundMuleScore,
    scamScore: scamScore,
  );

  Map<String, Object?> toDoc() => <String, Object?>{
    'sim_swap': simSwap,
    'call_active': callActive,
    'screen_share': screenShare,
    'caller_in_contacts': callerInContacts,
    'persona': persona?.uid,
    'forced_safety_verdict': forcedSafetyVerdict?.wire,
    'scam_score': scamScore,
    'integrity_scenario': integrityScenario,
    'inbound_mule_score': inboundMuleScore,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DemoState &&
          simSwap == other.simSwap &&
          callActive == other.callActive &&
          screenShare == other.screenShare &&
          callerInContacts == other.callerInContacts &&
          persona == other.persona &&
          forcedSafetyVerdict == other.forcedSafetyVerdict &&
          scamScore == other.scamScore &&
          integrityScenario == other.integrityScenario;

  @override
  int get hashCode => Object.hash(
    simSwap,
    callActive,
    screenShare,
    callerInContacts,
    persona,
    forcedSafetyVerdict,
    scamScore,
    integrityScenario,
  );

  @override
  String toString() => 'DemoState(${toDoc()})';
}

/// Simulated-world flags per user (Firestore doc or local store).
abstract class DemoStateRepo {
  /// Emits the current state on subscribe, then every write.
  Stream<DemoState> watch(String uid);
  Future<void> write(String uid, DemoState s);

  /// Writes [DemoState.initial].
  Future<void> reset(String uid);
}
