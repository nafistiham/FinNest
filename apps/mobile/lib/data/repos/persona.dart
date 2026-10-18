/// The two bundled demo personas.
///
/// Values come from `data/seed/users.jsonl`; `pin` is never stored here,
/// only its SHA-256 lives in `assets/demo/personas.json`.
enum Persona {
  rina('rina', trustedContactUid: 'rafiq', p95SendBdt: 5000),
  rahima('rahima', trustedContactUid: 'rafiq', p95SendBdt: 2000);

  const Persona(
    this.uid, {
    required this.trustedContactUid,
    required this.p95SendBdt,
  });

  /// The seed uid, also the `X-Demo-User` value and the Firestore doc id.
  final String uid;
  final String trustedContactUid;
  final double p95SendBdt;

  /// Seed convention: `acct_<uid>`.
  String get acctId => 'acct_$uid';

  /// Parses a seed uid; `null` for anything that is not a bundled persona.
  static Persona? tryParse(String? uid) {
    if (uid == null) return null;
    for (final p in values) {
      if (p.uid == uid) return p;
    }
    return null;
  }

  /// Parses a seed uid; throws [FormatException] for unknown values.
  static Persona parse(String uid) =>
      tryParse(uid) ?? (throw FormatException('Unknown persona "$uid"'));
}

extension PersonaParsing on String {
  /// `'rina'.asPersona == Persona.rina`; `null` when unknown.
  Persona? get asPersona => Persona.tryParse(this);
}
