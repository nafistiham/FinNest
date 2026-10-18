/// Text folding for the on-device safety search.
///
/// The same Bangla word reaches the app in several byte forms: keyboards
/// type the nukta letters precomposed or as base + nukta, split vowel signs
/// (ে + া) or the single sign (ো), and khanda ta with or without a joiner.
/// Speech-to-text and casual typing also mix long and short vowels (ী/ি,
/// ূ/ু). Dart has no Unicode NFC, so a small fold table maps every variant to
/// one form; the index and the query both go through [BanglaNormalizer.fold],
/// so they always agree.
library;

abstract final class BanglaNormalizer {
  /// Ordered rewrites. Order matters: the khanda ta sequence needs its ZWJ,
  /// so it is folded before the joiners are removed.
  static const List<(String, String)> _rewrites = [
    // Nukta letters, decomposed (base + U+09BC) and precomposed.
    ('ড়', 'ড'), // ড় -> ড
    ('ঢ়', 'ঢ'), // ঢ় -> ঢ
    ('য়', 'য'), // য় -> য
    ('ড়', 'ড'),
    ('ঢ়', 'ঢ'),
    ('য়', 'য'),
    // Split two-part vowel signs to the single sign.
    ('ো', 'ো'), // ে + া -> ো
    ('ৌ', 'ৌ'), // ে + ৗ -> ৌ
    // Khanda ta written as ত + virama + ZWJ.
    ('ত্‍', 'ৎ'),
    // Joiners carry no meaning for search.
    ('‌', ''),
    ('‍', ''),
    // Long and short vowels are mixed freely; fold for recall.
    ('ী', 'ি'), // ী -> ি
    ('ূ', 'ু'), // ূ -> ু
  ];

  /// Anything that is not a letter, mark, number or space (this includes
  /// the dari । and double dari ॥).
  static final RegExp _punctuation = RegExp(
    r'[^\p{L}\p{M}\p{N}\s]',
    unicode: true,
  );

  static final RegExp _word = RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true);

  /// Bengali digit zero (০).
  static const int _bnZero = 0x09E6;

  /// The boundary marker of [trigrams].
  static const String boundary = '#';

  /// [s] in the one form the index uses: folded Bangla, ASCII digits,
  /// lowercase Latin, punctuation turned into spaces.
  static String fold(String s) {
    var out = s;
    for (final (from, to) in _rewrites) {
      out = out.replaceAll(from, to);
    }
    return _asciiDigits(out).toLowerCase().replaceAll(_punctuation, ' ');
  }

  /// The words of [s] after [fold]. A Unicode class is used because Dart's
  /// `\w` breaks Bangla words at every vowel sign.
  static List<String> tokens(String s) => [
    for (final m in _word.allMatches(fold(s))) m.group(0)!,
  ];

  /// Character 3-grams of [token] padded with [boundary] on both sides, so
  /// word starts and ends count. Empty when the padded token is shorter than
  /// three code units (never for a non-empty token).
  static List<String> trigrams(String token) {
    final padded = '$boundary$token$boundary';
    if (padded.length < 3) return const [];
    return [
      for (var i = 0; i + 3 <= padded.length; i++) padded.substring(i, i + 3),
    ];
  }

  static String _asciiDigits(String s) {
    final units = s.codeUnits;
    var changed = false;
    final out = List<int>.of(units);
    for (var i = 0; i < out.length; i++) {
      final d = out[i] - _bnZero;
      if (d >= 0 && d <= 9) {
        out[i] = 0x30 + d;
        changed = true;
      }
    }
    return changed ? String.fromCharCodes(out) : s;
  }
}
