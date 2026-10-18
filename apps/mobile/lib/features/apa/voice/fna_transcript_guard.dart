/// The transcript guard of FNA voice mode: the
/// rules the code enforces, not only the prompt.
///
/// Pure and synchronous. The session runs it on the accumulated text of the
/// current turn every time a transcript chunk arrives, so a code split over
/// two chunks ("০১২" + "৩৪") is still caught.
///
/// One number reader serves every path: [FnaTranscriptGuard.redact] masks
/// typed text (chat, typed-in-voice, the text agent, `check_caller_words`,
/// the spoken call summary, through `ApaAnswers.redactSecrets`),
/// [FnaTranscriptGuard.checkUser] reads what the customer said and
/// [FnaTranscriptGuard.checkModel] reads what FNA said.
///
/// The reader first drops invisible format characters (zero-width joiners
/// and spaces, word joiner, soft hyphen, BOM) and maps every Unicode decimal
/// digit (Bangla, Arabic-Indic, Devanagari, fullwidth, math bold) and the
/// superscript and subscript digits to ASCII. It then joins digits and
/// number words (Bangla, English, English in Bangla script, Banglish, 0 to
/// 99, "double"/"triple", hundreds and thousands) across up to three
/// non-letter characters (spaces count once, an emoji counts once), so
/// "১২ ৩৪", "1*2*3*4", "চার আট দুই নয়", "ফোর এইট টু ওয়ান", "char ath dui
/// ek", "চার হাজার আটশো একুশ" and "four thousand eight hundred twenty one"
/// are all four or more code digits.
library;

import 'package:bhorosha/features/apa/logic/apa_helpline.dart';
import 'package:bhorosha/features/apa/voice/fna_instructions.dart';

enum GuardVerdict {
  /// Nothing to act on.
  ok,

  /// The customer said a code-like number: end the session, drop its
  /// resumption handle, mask the caption.
  secretDigits,

  /// FNA asked for a PIN, OTP, password or code.
  secretAsk,

  /// FNA told the customer to send, release, approve, retry or continue a
  /// payment. Checked on every turn, held or not: FNA never tells anyone to
  /// move money (the name is kept from when it was checked only while held).
  proceedWhileHeld,

  /// FNA explained in its own words why money is held (FR-3): a hold word
  /// together with a reason word ("because", "কারণ", "জন্য", "so") or a
  /// risk word ("new payee", "নতুন প্রাপক"), while a payment is held.
  holdExplanation,

  /// FNA named a real bank, mobile-money service, telecom company or app.
  brandName,

  /// FNA said a link: a URL, a domain ("example.com"), or one spelled to
  /// get past a filter ("example (dot) com", "hxxps://", "ডট কম").
  link,

  /// FNA said four or more digits (or number words) that are not an allowed
  /// public number.
  digitsEcho,
}

class FnaTranscriptGuard {
  const FnaTranscriptGuard({this.extraAllowedNumbers = const {}});

  /// More numbers FNA may say (ASCII digits, no separators). Exact whole
  /// numbers only.
  final Set<String> extraAllowedNumbers;

  /// The national emergency number and the knowledge base's public lines,
  /// with the +880 forms of the mobile numbers. Exact whole numbers only: a
  /// part of one ("1320") is not allowed.
  static const knowledgeBaseNumbers = {
    '999',
    '16236',
    '16001',
    '01320010148',
    '8801320010148',
    '01320000888',
    '8801320000888',
  };

  /// [knowledgeBaseNumbers] and the FinNest helpline (`AppEnv.helpline`),
  /// joined, with its +880 form when it is a local number.
  static final Set<String> publicNumbers = {
    ...knowledgeBaseNumbers,
    ApaHelpline.digits,
    if (ApaHelpline.digits.startsWith('0')) '88${ApaHelpline.digits}',
  };

  /// The mask a redacted number becomes.
  static const mask = '••••';

  Set<String> get _allowed => extraAllowedNumbers.isEmpty
      ? publicNumbers
      : {...publicNumbers, ...extraAllowedNumbers};

  // ------------------------------------------------------------ folding

  static final _formatChars = RegExp(r'\p{Cf}', unicode: true);

  /// Folds Bangla spelling variants (nukta letters, chandrabindu, split
  /// vowel signs, ণ/ন) and lower-cases, and drops invisible format
  /// characters (joiners, zero-width spaces, soft hyphens), so a word
  /// matches however the keyboard or the recogniser wrote it. Every pattern
  /// below is folded.
  static String fold(String s) => s
      .replaceAll(_formatChars, '')
      .replaceAll('ড়', 'ড') // ড় -> ড
      .replaceAll('ঢ়', 'ঢ') // ঢ় -> ঢ
      .replaceAll('য়', 'য') // য় -> য
      .replaceAll('়', '') // nukta
      .replaceAll('ঁ', '') // chandrabindu
      .replaceAll('ো', 'ো') // ে + া -> ো
      .replaceAll('ৌ', 'ৌ') // ে + ৗ -> ৌ
      .replaceAll('ণ', 'ন')
      .replaceAll('’', "'")
      .toLowerCase();

  // ------------------------------------------------------- normalising

  static final _decimalDigit = RegExp(r'\p{Nd}', unicode: true);
  static final _digitCache = <int, int?>{};

  /// The value of a digit code point in any script, or null.
  static int? _digitValue(int cp) {
    if (cp >= 0x30 && cp <= 0x39) return cp - 0x30;
    if (cp < 0xB2) return null;
    switch (cp) {
      case 0xB2:
        return 2;
      case 0xB3:
        return 3;
      case 0xB9:
        return 1;
      case 0x2070:
        return 0;
    }
    if (cp >= 0x2074 && cp <= 0x2079) return cp - 0x2070; // ⁴-⁹
    if (cp >= 0x2080 && cp <= 0x2089) return cp - 0x2080; // ₀-₉
    if (cp >= 0x2460 && cp <= 0x2468) return cp - 0x245F; // ①-⑨
    return _digitCache.putIfAbsent(cp, () {
      if (!_decimalDigit.hasMatch(String.fromCharCode(cp))) return null;
      // Decimal digits come in runs of ten from zero (the math digits in
      // five runs back to back), so the value is the distance from the
      // start of the run, modulo ten.
      var start = cp;
      while (_decimalDigit.hasMatch(String.fromCharCode(start - 1))) {
        start--;
      }
      return (cp - start) % 10;
    });
  }

  /// [text] with format characters dropped and every digit as ASCII, and
  /// for each code unit of the result the offset in [text] it came from
  /// (one more entry at the end: `text.length`).
  static _Norm _normalize(String text) {
    final out = StringBuffer();
    final map = <int>[];
    var i = 0;
    while (i < text.length) {
      final cu = text.codeUnitAt(i);
      var cp = cu;
      var len = 1;
      if (cu >= 0xD800 && cu <= 0xDBFF && i + 1 < text.length) {
        final lo = text.codeUnitAt(i + 1);
        if (lo >= 0xDC00 && lo <= 0xDFFF) {
          cp = 0x10000 + ((cu - 0xD800) << 10) + (lo - 0xDC00);
          len = 2;
        }
      }
      final d = _digitValue(cp);
      if (d != null) {
        out.write(d);
        map.add(i);
      } else if (cp >= 0x80 &&
          _formatChars.hasMatch(text.substring(i, i + len))) {
        // dropped
      } else {
        out.write(text.substring(i, i + len));
        for (var k = 0; k < len; k++) {
          map.add(i + k);
        }
      }
      i += len;
    }
    map.add(text.length);
    return _Norm(out.toString(), map);
  }

  // ------------------------------------------------------- number reader

  /// Spoken numbers 0 to 99 and their digits. Natural spelling; folded in
  /// [_wordDigits].
  static const _numberWordList = <(String, int)>[
    ('শূন্য', 0), ('শুন্য', 0), ('জিরো', 0), //
    ('এক', 1), ('দুই', 2), ('তিন', 3), ('চার', 4), ('পাঁচ', 5), //
    ('ছয়', 6), ('ছয়', 6), ('সাত', 7), ('আট', 8), ('নয়', 9), ('নয়', 9),
    ('দু', 2), ('ছ', 6), ('ন', 9), // short forms; ন only inside a run
    ('দশ', 10), ('এগারো', 11), ('এগার', 11), ('বারো', 12), ('তেরো', 13),
    ('তের', 13), ('চৌদ্দ', 14), ('পনেরো', 15), ('পনের', 15), ('ষোলো', 16),
    ('ষোল', 16), ('সতেরো', 17), ('সতের', 17), ('আঠারো', 18), ('আঠার', 18),
    ('উনিশ', 19), ('বিশ', 20), ('কুড়ি', 20), ('একুশ', 21), ('বাইশ', 22),
    ('তেইশ', 23), ('চব্বিশ', 24), ('পঁচিশ', 25), ('ছাব্বিশ', 26),
    ('সাতাশ', 27), ('আঠাশ', 28), ('উনত্রিশ', 29), ('ত্রিশ', 30),
    ('একত্রিশ', 31), ('বত্রিশ', 32), ('তেত্রিশ', 33), ('চৌত্রিশ', 34),
    ('পঁয়ত্রিশ', 35), ('ছত্রিশ', 36), ('সাঁইত্রিশ', 37), ('আটত্রিশ', 38),
    ('উনচল্লিশ', 39), ('চল্লিশ', 40), ('একচল্লিশ', 41), ('বিয়াল্লিশ', 42),
    ('তেতাল্লিশ', 43), ('চুয়াল্লিশ', 44), ('পঁয়তাল্লিশ', 45),
    ('ছেচল্লিশ', 46), ('সাতচল্লিশ', 47), ('আটচল্লিশ', 48),
    ('উনপঞ্চাশ', 49), ('পঞ্চাশ', 50), ('একান্ন', 51), ('বাহান্ন', 52),
    ('তিপ্পান্ন', 53), ('চুয়ান্ন', 54), ('পঞ্চান্ন', 55), ('ছাপ্পান্ন', 56),
    ('সাতান্ন', 57), ('আটান্ন', 58), ('উনষাট', 59), ('ষাট', 60),
    ('একষট্টি', 61), ('বাষট্টি', 62), ('তেষট্টি', 63), ('চৌষট্টি', 64),
    ('পঁয়ষট্টি', 65), ('ছেষট্টি', 66), ('সাতষট্টি', 67), ('আটষট্টি', 68),
    ('উনসত্তর', 69), ('সত্তর', 70), ('একাত্তর', 71), ('বাহাত্তর', 72),
    ('তিয়াত্তর', 73), ('চুয়াত্তর', 74), ('পঁচাত্তর', 75), ('ছিয়াত্তর', 76),
    ('সাতাত্তর', 77), ('আটাত্তর', 78), ('উনআশি', 79), ('ঊনআশি', 79),
    ('আশি', 80), ('একাশি', 81), ('বিরাশি', 82), ('তিরাশি', 83),
    ('চুরাশি', 84), ('পঁচাশি', 85), ('ছিয়াশি', 86), ('সাতাশি', 87),
    ('অষ্টআশি', 88), ('অষ্টাশি', 88), ('উননব্বই', 89), ('নব্বই', 90),
    ('একানব্বই', 91), ('বিরানব্বই', 92), ('তিরানব্বই', 93),
    ('চুরানব্বই', 94), ('পঁচানব্বই', 95), ('ছিয়ানব্বই', 96),
    ('সাতানব্বই', 97), ('আটানব্বই', 98), ('নিরানব্বই', 99),
    // English digits in Bangla script, as the recogniser writes them.
    ('ওয়ান', 1), ('টু', 2), ('থ্রি', 3), ('ফোর', 4), ('ফাইভ', 5), //
    ('সিক্স', 6), ('সেভেন', 7), ('এইট', 8), ('নাইন', 9), ('টেন', 10),
    // Banglish.
    ('shunno', 0), ('shunyo', 0), ('sunno', 0), ('ek', 1), ('dui', 2), //
    ('tin', 3), ('teen', 3), ('char', 4), ('panch', 5), ('pach', 5),
    ('choy', 6), ('chhoy', 6), ('choi', 6), ('sat', 7), ('saat', 7),
    ('at', 8), ('ath', 8), ('aat', 8), ('noy', 9), ('noi', 9),
    ('zero', 0), ('oh', 0), ('nil', 0), ('one', 1), ('two', 2), //
    ('three', 3), ('four', 4), ('five', 5), ('six', 6), ('seven', 7),
    ('eight', 8), ('nine', 9), ('ten', 10), ('eleven', 11), ('twelve', 12),
    ('thirteen', 13), ('fourteen', 14), ('fifteen', 15), ('sixteen', 16),
    ('seventeen', 17), ('eighteen', 18), ('nineteen', 19), ('twenty', 20),
    ('thirty', 30), ('forty', 40), ('fourty', 40), ('fifty', 50),
    ('sixty', 60), ('seventy', 70), ('eighty', 80), ('ninety', 90),
  ];

  static final Map<String, String> _wordDigits = {
    for (final (w, v) in _numberWordList) fold(w): '$v',
  };

  /// Number words that are also everyday words ("ন" is a piece of "না",
  /// "at", "sat", "tin", "teen", "char" are English): a number only next to
  /// another number word.
  static final _weakWords = {fold('ন'), 'at', 'sat', 'tin', 'teen', 'char'};

  /// Hundreds and thousands: "চার হাজার আটশো একুশ" is 4821.
  static final Map<String, int> _scaleWords = {
    fold('শো'): 100,
    fold('শ'): 100,
    fold('শত'): 100,
    fold('হাজার'): 1000,
    fold('লাখ'): 100000,
    fold('লক্ষ'): 100000,
    fold('কোটি'): 10000000,
    fold('হান্ড্রেড'): 100,
    fold('থাউজেন্ড'): 1000,
    'hundred': 100,
    'thousand': 1000,
    'hajar': 1000,
    'hazar': 1000,
    'lakh': 100000,
    'lac': 100000,
    'million': 1000000,
    'crore': 10000000,
  };

  /// "আটশো", "দুশ", "নয়শত": a digit word with a hundred ending.
  static final _hundredEndings = [fold('শো'), fold('শত'), fold('শ')];

  static int? _compoundHundred(String w) {
    for (final e in _hundredEndings) {
      if (!w.endsWith(e) || w.length <= e.length) continue;
      final d = _wordDigits[w.substring(0, w.length - e.length)];
      final v = d == null ? null : int.parse(d);
      if (v != null && v >= 1 && v <= 9) return v * 100;
    }
    return null;
  }

  static const _enTens = {
    'twenty',
    'thirty',
    'forty',
    'fourty',
    'fifty',
    'sixty',
    'seventy',
    'eighty',
    'ninety',
  };
  static const _enUnits = {
    'one',
    'two',
    'three',
    'four',
    'five',
    'six',
    'seven',
    'eight',
    'nine',
  };

  static final Map<String, int> _multipliers = {
    'double': 2,
    'triple': 3,
    fold('ডাবল'): 2,
    fold('ট্রিপল'): 3,
  };

  /// Digits, a word, a character that ends a number (%, a currency sign,
  /// other number signs), joining characters, anything else.
  static final _lexeme = RegExp(
    r'([0-9]+)|([\p{L}\p{M}]+)|([%‰\p{Sc}\p{N}])|([^\p{L}\p{M}\p{N}%‰\p{Sc}]+)',
    unicode: true,
  );

  static final _space = RegExp(r'\s');

  /// How far apart joining characters are: a run of white space counts
  /// once, every other character once.
  static int _sepUnits(String sep) {
    var n = 0;
    var inSpace = false;
    for (final r in sep.runes) {
      final space = _space.hasMatch(String.fromCharCode(r));
      if (!space || !inSpace) n++;
      inSpace = space;
    }
    return n;
  }

  /// The separator as the shape checks see it: white space dropped, or a
  /// single space when it was only white space.
  static String _sepKey(String sep) {
    final k = sep.replaceAll(_space, '');
    return k.isEmpty ? ' ' : k;
  }

  static String? _plainNumberOf(RegExpMatch m) {
    final d = m.group(1);
    if (d != null) return d;
    final w = m.group(2);
    return w == null ? null : _wordDigits[fold(w)];
  }

  /// Every run of digits and number words in [text] (normalised), joined
  /// across short joining punctuation.
  static List<_Run> _runs(String text) {
    // One element per number; null ends a run.
    final els = <_El?>[];
    String? pendingSep;

    void add(_El e) {
      final prev = els.isEmpty ? null : els.last;
      e.sep = prev == null ? '' : _sepKey(pendingSep ?? '');
      pendingSep = null;
      if (prev != null &&
          e.w != null &&
          _enUnits.contains(e.w) &&
          prev.w != null &&
          _enTens.contains(prev.w) &&
          (e.sep == ' ' || e.sep == '-' || e.sep == '–')) {
        // "forty-eight" is 48, not 4 0 8.
        prev
          ..digits = '${prev.digits[0]}${e.digits}'
          ..value = prev.value + e.value
          ..end = e.end
          ..w = null;
        return;
      }
      els.add(e);
    }

    void stop() {
      if (els.isNotEmpty && els.last != null) els.add(null);
      pendingSep = null;
    }

    final lex = _lexeme.allMatches(text).toList();
    for (var i = 0; i < lex.length; i++) {
      final m = lex[i];
      final sep = m.group(4);
      if (sep != null) {
        if (els.isEmpty || els.last == null) continue;
        if (_sepUnits(sep) > 3) {
          stop();
        } else {
          pendingSep = sep;
        }
        continue;
      }
      final word = m.group(2);
      if (word != null) {
        final w = fold(word);
        final times = _multipliers[w];
        if (times != null &&
            i + 2 < lex.length &&
            lex[i + 1].group(4) != null &&
            _sepUnits(lex[i + 1].group(4)!) <= 2) {
          final v = _plainNumberOf(lex[i + 2]);
          if (v != null) {
            final d = v * times;
            add(
              _El(m.start, lex[i + 2].end, d, int.tryParse(d) ?? 0)
                ..word = true,
            );
            i += 2;
            continue;
          }
        }
        final v = _wordDigits[w];
        if (v != null) {
          add(
            _El(m.start, m.end, v, int.parse(v))
              ..word = true
              ..w = w
              ..weak = _weakWords.contains(w),
          );
          continue;
        }
        final scale = _scaleWords[w];
        if (scale != null) {
          add(
            _El(m.start, m.end, '', 0)
              ..word = true
              ..scale = scale,
          );
          continue;
        }
        final hundred = _compoundHundred(w);
        if (hundred != null) {
          add(
            _El(m.start, m.end, '$hundred', hundred)
              ..word = true
              ..compound = true,
          );
          continue;
        }
        stop();
        continue;
      }
      final digits = m.group(1);
      if (digits != null) {
        add(_El(m.start, m.end, digits, int.tryParse(digits) ?? 0));
        continue;
      }
      stop();
    }

    // A weak word with no strong number word beside it is a plain word; a
    // scale word with no number before it ("হাজার হাজার মানুষ") is too.
    // A weak word next to a kept one is kept too ("ek dui tin char").
    final kept = <int>{};
    for (var changed = true; changed;) {
      changed = false;
      for (var k = 0; k < els.length; k++) {
        final e = els[k];
        if (e == null || !e.weak || kept.contains(k)) continue;
        bool ok(int i) => _strongWordAt(els, i) || kept.contains(i);
        if (ok(k - 1) || ok(k + 1)) changed = kept.add(k);
      }
    }
    for (var k = 0; k < els.length; k++) {
      if (els[k] != null && els[k]!.weak && !kept.contains(k)) els[k] = null;
    }
    for (var k = 0; k < els.length; k++) {
      final e = els[k];
      if (e == null || e.scale == 0) continue;
      final prev = k > 0 ? els[k - 1] : null;
      if (prev == null || (prev.scale != 0 && prev.scale <= e.scale)) {
        els[k] = null;
      }
    }

    final out = <_Run>[];
    var group = <_El>[];
    void close() {
      if (group.isNotEmpty) out.add(_Run.of(group));
      group = <_El>[];
    }

    for (final e in els) {
      if (e == null) {
        close();
      } else {
        group.add(e);
      }
    }
    close();
    return out;
  }

  static bool _strongWordAt(List<_El?> els, int k) {
    if (k < 0 || k >= els.length) return false;
    final e = els[k];
    return e != null && e.word && !e.weak && e.scale == 0;
  }

  /// A money amount is not a code: "৫০০০ টাকা", "5,000 tk", "৳ 5000",
  /// "Tk 5,000", "৫,০০০/-".
  static final _moneyAfter = RegExp(
    '^\\s*(?:${fold('টাকা')}|৳|/-|(?:taka|tk|bdt|rs)\\b)',
    caseSensitive: false,
  );
  static final _moneyBefore = RegExp(
    '(?:৳|${fold('টাকা')}|\\b(?:tk|bdt|taka|rs)\\.?)\\s*\$',
    caseSensitive: false,
  );
  static final _yearAfter = RegExp(
    '^\\s*(?:${fold('সাল')}|${fold('খ্রি')}|year\\b)',
  );

  /// "Can I send 15000", "আমি ৫০০০ পাঠাব": an amount the customer is
  /// about to send.
  static const _enSendWords = {
    'send', 'sending', 'sent', 'pay', 'paying', 'paid', 'transfer', //
    'transferring', 'transferred',
  };
  static final _bnSendAfter = RegExp(
    '^[^\\p{L}\\p{M}]*(?:${fold('পাঠা')}|${fold('পাঠি')}|${fold('পেমেন্ট')}'
    '|${fold('ট্রান্সফার')}|${fold('সেন্ড')})',
    unicode: true,
  );

  static final _wordRe = RegExp(r"[\p{L}\p{M}']+", unicode: true);

  static List<String> _lastWords(String before, int n) {
    final from = before.length > 120 ? before.length - 120 : 0;
    final words = [
      for (final m in _wordRe.allMatches(before.substring(from)))
        fold(m.group(0)!),
    ];
    return words.length <= n ? words : words.sublist(words.length - n);
  }

  /// A PIN, OTP, password or code word up to three words before [start]:
  /// "কোড ৪৮২১৯৩ টাকা পাঠাতে লাগবে" is a code, not an amount.
  static bool _secretBefore(String text, int start) =>
      _lastWords(text.substring(0, start), 3).any(_isSecretNoun);

  static bool _sendNear(String before, String after) =>
      _lastWords(before, 3).any(_enSendWords.contains) ||
      _bnSendAfter.hasMatch(
        fold(after.length > 40 ? after.substring(0, 40) : after),
      );

  static bool _amountShape(_Run r) {
    if (r.scaled) return true;
    var gs = r.groups;
    var ss = r.seps;
    if (ss.isNotEmpty && ss.last == '.' && gs.last.length <= 2) {
      gs = gs.sublist(0, gs.length - 1);
      ss = ss.sublist(0, ss.length - 1);
    }
    if (gs.length == 1) return true;
    return ss.every((s) => s == ',') &&
        gs.first.length <= 3 &&
        gs.skip(1).every((g) => g.length == 2 || g.length == 3);
  }

  static bool _isYear(String g) =>
      g.length == 4 && (g.startsWith('19') || g.startsWith('20'));

  /// 1990 to 2035: a year, with or without "সাল".
  static bool _isRecentYear(String g) {
    if (g.length != 4) return false;
    final n = int.parse(g);
    return n >= 1990 && n <= 2035;
  }

  static bool _isDate(_Run r) {
    if (r.groups.length != 3 || r.seps.toSet().length != 1) return false;
    if (!const {'/', '-', '.'}.contains(r.seps.first)) return false;
    int n(String g) => int.parse(g);
    bool day(String g) => g.length <= 2 && n(g) >= 1 && n(g) <= 31;
    bool month(String g) => g.length <= 2 && n(g) >= 1 && n(g) <= 12;
    final [a, b, c] = r.groups;
    return (day(a) && month(b) && _isYear(c)) ||
        (_isYear(a) && month(b) && day(c));
  }

  /// "10:30": hours and minutes.
  static bool _isTime(_Run r) {
    if (r.groups.length != 2 || r.seps.single != ':') return false;
    final [h, m] = r.groups;
    return h.length <= 2 &&
        m.length == 2 &&
        int.parse(h) <= 23 &&
        int.parse(m) <= 59;
  }

  /// Whether [r] is a number that may show: an allowed whole number (or a
  /// list of them split by commas or slashes), or, unless a secret word
  /// comes just before it, a money amount, an amount being sent, a date, a
  /// time or a year.
  static bool _isExempt(String text, _Run r, Set<String> allowed) {
    if (allowed.contains(r.digits)) return true;
    // "৯৯৯, ১৬২৩৬": every part is itself a whole allowed number. "999 999"
    // is not.
    if (r.groups.length > 1 &&
        r.seps.every((s) => s == ',' || s == '/') &&
        r.groups.every(allowed.contains)) {
      return true;
    }
    if (_secretBefore(text, r.start)) return false;
    if (r.words && !r.scaled) return false;
    final before = text.substring(0, r.start);
    final after = text.substring(r.end);
    if (_amountShape(r)) {
      if (_moneyAfter.hasMatch(fold(after)) ||
          _moneyBefore.hasMatch(fold(before))) {
        return true;
      }
      if (r.digits.length <= 6 && _sendNear(before, after)) return true;
    }
    if (!r.words && (_isDate(r) || _isTime(r))) return true;
    if (r.groups.length != 1) return false;
    return _isRecentYear(r.digits) ||
        (_isYear(r.digits) && _yearAfter.hasMatch(fold(after)));
  }

  /// Whether [r] is four or more code digits that are not exempt.
  static bool _isCode(String text, _Run r, Set<String> allowed) =>
      r.digits.length >= 4 && !_isExempt(text, r, allowed);

  static List<_Run> _codes(String text, Set<String> allowed) => [
    for (final r in _runs(text))
      if (_isCode(text, r, allowed)) r,
  ];

  /// [text] with every code-like number (four or more digits or number
  /// words, joined as above) replaced by [mask], and whether any was.
  /// Amounts, dates, times, years and the public numbers stay, unless a
  /// PIN, OTP, password or code word comes just before them.
  static (String, bool) redact(String text) {
    final n = _normalize(text);
    final codes = _codes(n.text, publicNumbers);
    if (codes.isEmpty) return (text, false);
    final out = StringBuffer();
    var at = 0;
    for (final r in codes) {
      out
        ..write(text.substring(at, n.map[r.start]))
        ..write(mask);
      at = n.map[r.end];
    }
    out.write(text.substring(at));
    return (out.toString(), true);
  }

  /// [text] for a caption: every code-like run masked as [redact] does,
  /// the digits of any other number hidden too (a short number may be the
  /// first piece of a code still arriving), but the public numbers, amounts,
  /// dates and years left as they are, so "৯৯৯ নম্বরে কল করুন" still reads
  /// right.
  static String maskDigits(String text) {
    final n = _normalize(text);
    final out = StringBuffer();
    var at = 0;
    for (final r in _runs(n.text)) {
      if (_isExempt(n.text, r, publicNumbers)) continue;
      final start = n.map[r.start];
      final end = n.map[r.end];
      out.write(text.substring(at, start));
      final span = text.substring(start, end);
      // A code becomes the mask; a short number (maybe the first piece of
      // a code still arriving) keeps its words but hides its digits.
      out.write(r.digits.length >= 4 ? mask : span.replaceAll(_anyDigit, '•'));
      at = end;
    }
    out.write(text.substring(at));
    return out.toString();
  }

  static final _anyDigit = RegExp(r'[\p{Nd}¹²³⁰⁴-⁹₀-₉①-⑨]', unicode: true);

  // ---------------------------------------------------------------- links

  static final _dotLike = RegExp('[。．｡]');

  static const _tlds =
      'com|net|org|info|xyz|top|bd|io|me|co|app|link|site|online|shop|store'
      '|live|click|biz|pro|cc|ru|cn|in|gov|edu|ac|tk|ml|ga|cf|gq|ly|to|gl';

  /// A link: a URL (also "hxxps://" and "https[:]//"), "www." anything, a
  /// domain or a domain path ("evil.example/x") with a 2 to 24 letter last
  /// part, a dot written as "(dot)", "[.]" or " dot " before a common
  /// ending, or "ডট কম".
  static final linkPattern = RegExp(
    r'\b(?:h[xt]{2}ps?|ftp)\s*(?::|\[:\]|\(:\))\s*//\S*'
    r'|\bwww\s*(?:\.|\[\.\]|\(\.\)|\(dot\)|\[dot\])\s*\S+'
    r'|[\p{L}\p{N}_-]+(?:\s*(?:\.|\[\.\]|\(\.\)|\(dot\)|\[dot\]|\{dot\})\s*[\p{L}\p{N}_-]+)*'
    r'\s*(?:\[\.\]|\(\.\)|\(dot\)|\[dot\]|\{dot\})\s*[a-z]{2,24}\b\S*'
    r'|[\p{L}\p{N}_-]+(?:\.[\p{L}\p{N}_-]+)*\.[a-z]{2,24}\b(?:/\S*)?'
    '|[\\p{L}\\p{N}_-]+\\s+dot\\s+(?:$_tlds)\\b\\S*'
    '|ডট\\s*(?:কম|নেট|অর্গ|বিডি)',
    caseSensitive: false,
    unicode: true,
  );

  static String _linkReady(String text) =>
      text.replaceAll(_formatChars, '').replaceAll(_dotLike, '.');

  /// Whether [text] holds a link ([linkPattern]).
  static bool hasLink(String text) => linkPattern.hasMatch(_linkReady(text));

  /// [text] with format characters dropped and every link replaced by
  /// [replacement].
  static String maskLinks(String text, {String replacement = '[link]'}) =>
      _linkReady(text).replaceAll(linkPattern, replacement);

  // ------------------------------------------------------------ the checks

  /// The customer's accumulated turn text.
  GuardVerdict checkUser(String turnText) =>
      _codes(_normalize(turnText).text, _allowed).isEmpty
      ? GuardVerdict.ok
      : GuardVerdict.secretDigits;

  /// FNA's accumulated turn text. [held] is `true` while a payment is held,
  /// delayed or waiting for the trusted contact; it only turns on the FR-3
  /// hold-explanation check. The proceed check runs on every turn.
  ///
  /// [partial] is `true` for the text of a turn still streaming: when it
  /// does not end with a sentence mark, the ask and proceed checks ignore a
  /// last word that the next chunk may still negate ("টাকা পাঠাবেন" + " না",
  /// "You can" + " not"). Run a final check with `partial: false` when the
  /// turn completes.
  GuardVerdict checkModel(
    String turnText, {
    required bool held,
    bool partial = false,
  }) {
    final normal = _normalize(turnText).text;
    final text = fold(normal);
    final closed = partial ? _withoutOpenEnd(text) : text;
    if (_asksForSecret(closed)) return GuardVerdict.secretAsk;
    if (_namesBrand(text)) return GuardVerdict.brandName;
    if (hasLink(turnText)) return GuardVerdict.link;
    if (_tellsToProceed(closed)) return GuardVerdict.proceedWhileHeld;
    if (held && _explainsHold(text)) return GuardVerdict.holdExplanation;
    if (_codes(normal, _allowed).isNotEmpty) return GuardVerdict.digitsEcho;
    return GuardVerdict.ok;
  }

  // ------------------------------------------------- streaming open end

  static final _closedEnd = RegExp(r'[.!?।\n]\s*$');

  /// Last words that the next chunk may still turn into a refusal: Bangla
  /// future, polite and modal forms (না or নি may follow) and English verbs
  /// and auxiliaries ("not" or "until ..." may follow).
  static final _openEndWords = {
    ..._bnNegatable,
    ..._bnCompoundNegatable,
    ..._bnModal,
    ..._bnCueModal,
    ..._folded(const [
      'পাঠাবেন', 'দেবেন', 'দিবেন', 'করবেন', 'পারেন', 'পারবেন', 'লাগে', //
      'দরকার', 'চাই',
    ]),
    ..._enModals,
    ..._enAskVerbs,
    ..._enCueVerbs,
    'do', 'does', 'did', 'is', 'are', 'was', 'send', 'release', 'approve', //
    'transfer', 'pay', 'confirm', 'complete', 'unlock', 'unblock', 'resend',
    'retry', 'ahead', 'proceed', 'continue',
  };

  /// [text] (folded) without its last word when the text does not end with
  /// a sentence mark and that word is in [_openEndWords]: a streaming
  /// sentence is judged on what is sure so far.
  static String _withoutOpenEnd(String text) {
    if (text.trim().isEmpty || _closedEnd.hasMatch(text)) return text;
    final words = _tokenRe.allMatches(text);
    if (words.isEmpty) return text;
    final last = words.last;
    if (text.substring(last.end).trim().isNotEmpty) return text;
    return _openEndWords.contains(last.group(0))
        ? text.substring(0, last.start)
        : text;
  }

  // ------------------------------------------------------ "tell me the PIN"

  static final _sentence = RegExp(r'[^.!?।\n]+');
  static final _tokenRe = RegExp(
    r"[\p{L}\p{M}\p{N}']+(?:-[\p{L}\p{M}\p{N}']+)*",
    unicode: true,
  );

  static List<String> _tokens(String s) => [
    for (final m in _tokenRe.allMatches(s)) m.group(0)!,
  ];

  static Set<String> _folded(Iterable<String> words) => {
    for (final w in words) fold(w),
  };

  static final _secretNoun = RegExp(
    '^(?:${fold('পিন')}|${fold('ওটিপি')}|${fold('কোড')}|${fold('পাসওয়ার্ড')}'
    '|${fold('পাসকোড')}|otp|pin|code|password|passcode)'
    '(?:s|${fold('টা')}|${fold('টি')}|${fold('টাও')}|${fold('টিও')}'
    '|${fold('টাই')}|${fold('গুলো')}|${fold('গুলি')}|${fold('ও')}'
    '|${fold('ই')}|${fold('ের')}|${fold('এর')}|${fold('টার')}|${fold('টির')})?\$',
    unicode: true,
  );

  static bool _isSecretNoun(String t) => t.split('-').any(_secretNoun.hasMatch);

  static final _bnNew = fold('নতুন');
  static final _bnSetVerbs = _folded(const ['দিন', 'লিখুন', 'সেট']);
  static final _bnChange = _folded(const ['বদলে', 'পরিবর্তন', 'চেঞ্জ']);
  static final _bnDoneDo = fold('করে');

  /// The secret at [i] is a new value the customer sets, not one they
  /// tell: "নতুন পাসওয়ার্ড দিন", "নতুন পিন সেট করুন", "পিন বদলে নতুন পিন
  /// দিন", "পাসওয়ার্ড পরিবর্তন করে নতুন ...".
  static bool _bnSetsNew(List<String> t, int i) {
    String at(int k) => k >= 0 && k < t.length ? t[k] : '';
    if (at(i - 1) == _bnNew && _bnSetVerbs.contains(at(i + 1))) return true;
    if (!_bnChange.contains(at(i + 1))) return false;
    if (at(i + 2) == _bnNew) return true;
    return at(i + 2) == _bnDoneDo && at(i + 3) == _bnNew;
  }

  static const _enTypeVerbs = {'type', 'enter', 'input', 'put', 'write'};
  static const _enTalkVerbs = {
    'tell', 'share', 'give', 'send', 'say', 'read', 'repeat', 'spell', //
    'forward', 'text', 'dictate', 'recite', 'show', 'provide', 'confirm',
    'submit', 'paste',
  };

  /// "You can type your PIN only inside the FinNest app": typed into the
  /// app itself, not told to anyone. The secret at [i] is followed by
  /// "(only) in/inside the (FinNest) app" and the clause only types it.
  static bool _enInApp(List<String> t, int i) {
    var k = i + 1;
    if (k < t.length && t[k] == 'only') k++;
    if (k >= t.length || (t[k] != 'in' && t[k] != 'inside')) return false;
    k++;
    if (k < t.length && t[k] == 'the') k++;
    if (k < t.length && t[k] == 'finnest') k++;
    if (k >= t.length || t[k] != 'app') return false;
    return t.sublist(0, i).any(_enTypeVerbs.contains) &&
        !t.any(_enTalkVerbs.contains);
  }

  /// A secret word that is not an ask target ([_bnSetsNew], [_enInApp]).
  static bool _settable(List<String> t, int i) =>
      _bnSetsNew(t, i) || _enInApp(t, i);

  /// Imperatives: an ask even with না after ("কোড বলুন না" is polite
  /// insistence, not a refusal).
  static final _bnImperative = _folded(const [
    'বলুন', 'বলেন', 'বলো', 'বল', 'দিন', 'দেন', 'দাও', 'পাঠান', 'পাঠাও', //
    'লিখুন', 'লেখেন', 'লেখো', 'জানান', 'জানাও', 'শোনান',
  ]);

  /// Future and polite forms: an ask unless না follows ("বলবেন না").
  static final _bnNegatable = _folded(const [
    'বলবেন', 'দেবেন', 'দিবেন', 'পাঠাবেন', 'লিখবেন', 'জানাবেন', //
    'শোনাবেন', 'বলবে', 'দেবে', 'দিও', 'বোলো', 'বলিও', 'পাঠিও',
  ]);

  /// "শেয়ার করুন", "টাইপ করবেন".
  static final _bnCompoundHead = _folded(const [
    'শেয়ার',
    'টাইপ',
    'এন্টার',
    'ইনপুট',
    'কপি',
    'পেস্ট',
    'সেন্ড',
  ]);
  static final _bnCompoundImperative = _folded(const ['করুন', 'করেন', 'করো']);
  static final _bnCompoundNegatable = _folded(const ['করবেন', 'করবে']);

  /// "বলতে পারবেন", "দিতে হবে".
  static final _bnInfinitive = _folded(const [
    'বলতে',
    'দিতে',
    'পাঠাতে',
    'জানাতে',
    'লিখতে',
    'শোনাতে',
  ]);
  static final _bnModal = _folded(const [
    'পারবেন',
    'পারেন',
    'হবে',
    'হচ্ছে',
    'লাগবে',
  ]);

  static final _bnNegation = _folded(const ['না', 'নয়', 'নেই', 'নি']);

  /// Words between the noun and the verb that end the search: a third
  /// party's ask ("কেউ কোড চাইলে"), a condition, a negation, or a verb that
  /// destroys or blocks ("মুছে দিন", "কেটে দিন").
  static final _bnBreak = _folded(const [
    'চাইলে',
    'চায়',
    'চাইছে',
    'চাইবে',
    'চেয়ে',
    'চাইতে',
    'চাওয়া',
    'চাইলেও',
    'চাইছেন',
    'চান',
    'পেলে',
    'বললে',
    'করলে',
    'দিলে',
    'এলে',
    'আসলে',
    'আসে',
    'গেলে',
    'যদি',
    'কেউ',
    'কেউই',
    'কখনো',
    'কখনোই',
    'না',
    'নয়',
    'নেই',
    'কেটে',
    'মুছে',
    'ফেলে',
    'রেখে',
    'ছেড়ে',
    'ঢেকে',
    'লুকিয়ে',
    'বন্ধ',
    'ব্লক',
    'রিপোর্ট',
    'এড়িয়ে',
    'কিন্তু',
    'তাহলে',
    'তবে',
    'বরং',
  ]);

  /// "দুই দিন পর": দিন is "day" here.
  static final _bnDayBefore = _folded(const [
    'কয়েক',
    'কত',
    'সেই',
    'আজ',
    'প্রতি',
    'সারা',
    'ওই',
    'এই',
  ]);
  static final _bnDayAfter = _folded(const [
    'পর',
    'পরে',
    'আগে',
    'ধরে',
    'বাদে',
    'ধরেই',
    'এর',
    'ধরে',
  ]);

  static final _bnPossessive = _folded(const ['আপনার', 'তোমার', 'তোর']);
  static final _bnHowMuch = fold('কত');
  static final _bnWhat = _folded(const ['কী', 'কি', 'কোনটা']);
  static final _bnNumberNoun = _folded(const ['নম্বর', 'নম্বরটা', 'টা', 'টি']);

  static bool _isNumberish(String t) =>
      _wordDigits.containsKey(t) || RegExp(r'^[0-9০-৯]+$').hasMatch(t);

  /// Bangla puts the noun first: "কোডটা আমাকে বলুন" (up to three words
  /// between), "আপনার ওটিপি কত".
  static bool _asksBn(List<String> t) {
    for (var i = 0; i < t.length; i++) {
      if (!_isSecretNoun(t[i]) || _settable(t, i)) continue;
      // "আপনার ওটিপি কত?", "আপনার পিন নম্বর কী?"
      var k = i + 1;
      while (k < t.length && _bnNumberNoun.contains(t[k])) {
        k++;
      }
      if (k == t.length - 1) {
        final possessed =
            (i > 0 && _bnPossessive.contains(t[i - 1])) ||
            (i > 1 && _bnPossessive.contains(t[i - 2]));
        if (t[k] == _bnHowMuch) return true;
        if (possessed && _bnWhat.contains(t[k])) return true;
      }
      for (var j = i + 1; j < t.length && j <= i + 4; j++) {
        final w = t[j];
        if (_bnBreak.contains(w)) break;
        final next = j + 1 < t.length ? t[j + 1] : '';
        final prev = t[j - 1];
        if (w == fold('দিন') &&
            (_isNumberish(prev) ||
                _bnDayBefore.contains(prev) ||
                _bnDayAfter.contains(next))) {
          continue;
        }
        final compound = _bnCompoundHead.contains(prev);
        if (_bnImperative.contains(w) ||
            (compound && _bnCompoundImperative.contains(w))) {
          return true;
        }
        if (_bnNegatable.contains(w) ||
            (compound && _bnCompoundNegatable.contains(w))) {
          if (!_bnNegation.contains(next)) return true;
          break;
        }
        if (_bnInfinitive.contains(w)) {
          if (_bnModal.contains(next)) {
            final after = j + 2 < t.length ? t[j + 2] : '';
            if (!_bnNegation.contains(after)) return true;
          }
          break;
        }
      }
    }
    return false;
  }

  static const _enAskVerbs = {
    'tell', 'share', 'give', 'send', 'say', 'read', 'type', 'enter', //
    'provide', 'repeat', 'confirm', 'spell', 'show', 'forward', 'text',
  };
  static const _enDeterminers = {
    'your',
    'the',
    'that',
    'this',
    'those',
    'these',
  };

  /// Words between the verb and the noun that make it not an ask ("tell me
  /// if anyone asks for your PIN").
  static const _enBreak = {
    'if', 'when', 'whether', 'about', 'anyone', 'anybody', 'someone', //
    'somebody', 'nobody', 'no', 'never', 'ask', 'asks', 'asked', 'asking',
    'for', 'who', 'unless', 'because', 'how', 'why', 'to', 'what', 'which',
    'where', 'them', 'him', 'her', 'police', 'helpline',
  };
  static const _enNegation = {
    'not', 'never', "don't", 'dont', 'cannot', "can't", 'cant', "won't", //
    'wont', "shouldn't", 'shouldnt', "mustn't", 'mustnt', 'unable', 'no',
  };
  static const _enSoftAdverbs = {'ever', 'please', 'really', 'also', 'just'};

  static bool _enNegatedBefore(List<String> t, int j) {
    var k = j - 1;
    if (k >= 0 && _enSoftAdverbs.contains(t[k])) k--;
    if (k < 0) return false;
    if (_enNegation.contains(t[k])) return true;
    // "never agree to share", "not allowed to tell"
    if (t[k] == 'to') {
      for (var b = k - 1; b >= 0 && b >= k - 3; b--) {
        if (_enNegation.contains(t[b])) return true;
      }
    }
    return false;
  }

  static bool _asksEn(List<String> t) {
    for (var j = 0; j < t.length; j++) {
      if (!_enAskVerbs.contains(t[j])) continue;
      // "They will tell you to share your PIN": a scammer, described.
      if (t
          .sublist(j - 5 < 0 ? 0 : j - 5, j)
          .any(
            const {
              'they',
              'scammer',
              'scammers',
              'fraudster',
              'fraudsters',
              'caller',
              'callers',
            }.contains,
          )) {
        continue;
      }
      // "If you enter your PIN there, ...": a condition, not an ask.
      final lead = t.sublist(j - 3 < 0 ? 0 : j - 3, j);
      if (lead.any(
        const {'if', 'when', 'whether', 'once', 'unless'}.contains,
      )) {
        continue;
      }
      // "Only you type your PIN": a statement. "Can you tell me ...": an ask.
      if (j > 0 && const {'you', 'i', 'we', 'they'}.contains(t[j - 1])) {
        final before = j > 1 ? t[j - 2] : '';
        if (!_enModals.contains(before) && before != 'please') continue;
      }
      var determiner = false;
      for (var k = j + 1; k < t.length && k <= j + 5; k++) {
        if (_enBreak.contains(t[k])) break;
        if (_enDeterminers.contains(t[k])) determiner = true;
        if (_isSecretNoun(t[k])) {
          if (_settable(t, k)) break;
          // "Read the code SMS" is advice; "read me the code" is an ask.
          final toUs = t
              .sublist(j + 1, k)
              .any(const {'me', 'us', 'out', 'aloud', 'fna'}.contains);
          if (t[j] == 'read' && !toUs) break;
          if (determiner && !_enNegatedBefore(t, j)) return true;
          break;
        }
      }
    }
    return false;
  }

  static const _enNoun = '(?:otp|pin|code|password|passcode)s?';

  /// "what's your PIN", "what is the OTP", "what code did you get".
  static final _whatIs = RegExp(
    "\\bwhat(?:'s|\\s+is|\\s+was|\\s+are|\\s+were)\\s+(?:your|the|that|this)"
    '\\s+(?:[\\w-]+\\s+)?$_enNoun\\b'
    r'(?!\s+(?:scam|scams|fraud|rule|rules|message|sms|trick|tricks)\b)'
    '|\\bwhat\\s+$_enNoun\\s+(?:did|do|have)\\s+you\\b',
  );

  static bool _asksForSecret(String text) {
    for (final s in _sentence.allMatches(text)) {
      final sentence = s.group(0)!;
      if (_whatIs.hasMatch(sentence)) return true;
      final t = _tokens(sentence);
      if (_asksBn(t) || _asksEn(t) || _asksStrict(sentence)) return true;
    }
    return false;
  }

  // ------------------------------------------- the strict rule (any ask)

  /// Clauses: a comma, semicolon or colon, or "and"/"but"/"এবং"/"কিন্তু".
  static final _clauseSplit = RegExp(
    '[,;:]|\\b(?:and|but)\\b|${fold('এবং')}|${fold('কিন্তু')}',
  );

  /// "সংখ্যাগুলো", "digits": a secret only next to an SMS word.
  static final _numberNoun = RegExp(
    '^(?:${fold('সংখ্যা')}|${fold('নম্বর')}|${fold('ডিজিট')}|digit|digits'
    '|number|numbers)(?:${fold('গুলো')}|${fold('গুলি')}|${fold('টা')}'
    '|${fold('টি')}|${fold('গুলোও')})?\$',
  );
  static final _smsWord = RegExp(
    '^(?:sms|message|messages|text|texts|${fold('এসএমএস')}|${fold('মেসেজ')}'
    '|${fold('ম্যাসেজ')})',
  );
  static final _qr = _folded(const ['qr', 'কিউআর']);

  /// Words that make a Bangla clause a prohibition or a description of a
  /// scammer's ask: a negation, "never", "to anyone", "forbidden", or a
  /// third person who asks ("চায়", "চাইলে").
  static final _bnStop = _folded(const [
    'না', 'নয়', 'নেই', 'নি', 'নাই', 'কখনো', 'কখনোই', 'কখনও', 'কাউকে', //
    'মানা', 'নিষেধ', 'চায়', 'চাইবে', 'চাইলে', 'চাইছে', 'চেয়েছে',
    'চেয়েছিল', 'চাইলেও', 'কেউ', 'কেউই',
  ]);
  static final _bnScammer = fold('প্রতারক');

  /// Someone other than FNA is told ("এসএমএস পড়ে তাদের বলুন").
  static final _bnAddressees = _folded(const [
    'তাদের', 'ওদের', 'তাকে', 'ওকে', 'হেল্পলাইনে', 'হেল্পলাইনকে', //
    'পুলিশকে', 'পুলিশে', 'থানায়', 'ব্যাংকে',
  ]);

  /// Bangla request verbs.
  static final _bnCues = _folded(const [
    'বলুন', 'বলেন', 'বলো', 'বল', 'দিন', 'দেন', 'দাও', 'পাঠান', 'পাঠাও', //
    'লিখুন', 'লেখেন', 'লেখো', 'জানান', 'জানাও', 'শোনান', 'দেখান', 'দেখাও',
    'বলবেন', 'দেবেন', 'দিবেন', 'পাঠাবেন', 'লিখবেন', 'জানাবেন', 'শোনাবেন',
    'দেখাবেন', 'চাই', 'লাগবে', 'লাগে', 'দরকার',
  ]);
  static final _bnCueInfinitive = _folded(const [
    // No করতে: "রিসেট করতে হবে" is advice; "শেয়ার করতে হবে" is caught by
    // the compound head check.
    'বলতে', 'দিতে', 'পাঠাতে', 'জানাতে', 'লিখতে', 'শোনাতে', 'জানতে', //
    'দেখাতে', 'চাইতে', 'নিতে',
  ]);
  static final _bnCueModal = _folded(const [
    'পারবেন', 'পারেন', 'হবে', 'হচ্ছে', 'লাগবে', 'চাই', 'চাইছি', 'পারি', //
    'দরকার',
  ]);

  /// "দিন" after these is not "give": "মুছে দিন", "কেটে দিন".
  static final _bnNotGive = _folded(const [
    'মুছে', 'কেটে', 'ফেলে', 'রেখে', 'ঢেকে', 'লুকিয়ে', 'বন্ধ', 'ব্লক', //
    'রিপোর্ট', 'ডিলিট', 'বদলে', 'ছেড়ে', 'চাপ', 'সরিয়ে', 'আটকে', 'থামিয়ে',
    'এড়িয়ে', 'ফিরিয়ে', 'চালু',
  ]);
  static final _bnKor = fold('কর');
  static final _bnWhich = _folded(const ['কোন', 'কোনটা', 'কোনটি']);
  static final _bnHowMuchNotAsk = _folded(const [
    'দিন', 'দিনে', 'দিনের', 'সময়', 'মিনিট', 'বার', 'ঘণ্টা', 'সংখ্যার', //
    'ডিজিটের', 'টাকা', 'অক্ষরের',
  ]);
  static final _bnWhatNotAsk = _folded(const ['কাজে', 'জন্য', 'ধরনের', 'রকম']);
  static final _bnOnly = fold('শুধু');
  static final _bnYouWord = fold('আপনি');

  static const _enStop = {
    'not', 'never', "don't", 'dont', 'no', 'nobody', 'cannot', "can't", //
    'cant', "won't", 'wont', "shouldn't", 'shouldnt', "mustn't", 'mustnt',
    'nor', 'neither',
  };
  static const _enCondLead = {
    'if', 'when', 'whenever', 'once', 'unless', 'whether', 'while', 'after', //
    'before', 'until',
  };
  static const _enFillers = {
    'please', 'kindly', 'now', 'then', 'so', 'ok', 'okay', 'just', 'also', //
    'quickly', 'first', 'next', 'sir', 'madam', 'maam', "ma'am", 'apa',
    'bhai', 'dear', 'hey', 'yes', 'right', 'well', 'simply',
  };
  static const _enCueVerbs = {
    'tell', 'share', 'give', 'send', 'say', 'type', 'enter', 'input', //
    'provide', 'repeat', 'confirm', 'spell', 'show', 'forward', 'text',
    'read', 'dictate', 'submit', 'put', 'write', 'paste', 'recite',
  };
  static const _enFirstPersonCues = {
    'need',
    'want',
    'have',
    'know',
    'ask',
    'get',
    'see',
    'check',
    'verify',
  };
  static const _enFirstPerson = {
    'i',
    'we',
    'me',
    'us',
    "i'd",
    "i'll",
    "we'll",
    "we'd",
    "i'm",
  };
  static const _enToCue = {'need', 'have', 'has', 'must', 'got', 'want'};
  static const _enAddressees = {
    'them', 'him', 'her', 'police', 'helpline', 'bank', 'staff', 'anyone', //
    'anybody', 'someone', 'nobody',
  };
  static const _enReadTo = {'out', 'aloud', 'me', 'us'};
  static const _enWhatNotAsk = {
    'scam', 'scams', 'fraud', 'trick', 'tricks', 'rule', 'rules', 'means', //
    'mean', 'is', 'are',
  };

  /// The strict rule: a clause with a secret (a PIN, OTP, password or code
  /// word, or "digits" next to an SMS word) and a request directed at the
  /// customer, unless it is a prohibition ("never", "বলবেন না", "কাউকে"),
  /// describes a scammer ("প্রতারক … চায়", "they ask"), is a condition
  /// ("If you enter your PIN there, …") or tells a third party ("tell
  /// them").
  static bool _asksStrict(String sentence) {
    for (final clause in sentence.split(_clauseSplit)) {
      final t = _tokens(clause);
      if (t.isNotEmpty && _clauseAsks(t)) return true;
    }
    return false;
  }

  static bool _clauseAsks(List<String> t) {
    final sms = t.any(_smsWord.hasMatch);
    final nouns = <int>[
      for (var i = 0; i < t.length; i++)
        if ((_isSecretNoun(t[i]) &&
                !(i > 0 && _qr.contains(t[i - 1])) &&
                !_settable(t, i)) ||
            (sms && _numberNoun.hasMatch(t[i])))
          i,
    ];
    if (nouns.isEmpty) return false;
    if (t.any(_bnStop.contains) || t.any(_bnAddressees.contains)) return false;
    if (t.any((w) => w.startsWith(_bnScammer))) return false;
    if (_enCondLead.contains(t.first)) return false;
    for (var i = 0; i + 1 < t.length; i++) {
      if ((t[i] == 'only' && t[i + 1] == 'you') ||
          (t[i] == _bnOnly && t[i + 1] == _bnYouWord)) {
        return false;
      }
    }
    for (var j = 0; j < t.length; j++) {
      if (_bnCue(t, j, nouns)) return true;
      if (!_enCue(t, j, nouns)) continue;
      if (t.sublist(0, j).any(_enStop.contains)) continue;
      // "tell them what the code was for": a third party; "tell me if
      // anyone asks for your PIN": not about the secret.
      final after = nouns.where((k) => k > j);
      if (after.isNotEmpty &&
          nouns.every((k) => k > j) &&
          t
              .sublist(j + 1, after.first)
              .any((w) => _enBreak.contains(w) || _enAddressees.contains(w))) {
        continue;
      }
      if (j + 1 < t.length && _enAddressees.contains(t[j + 1])) continue;
      return true;
    }
    return false;
  }

  static bool _bnCue(List<String> t, int j, List<int> nouns) {
    final w = t[j];
    final prev = j > 0 ? t[j - 1] : '';
    final next = j + 1 < t.length ? t[j + 1] : '';
    if (_bnCues.contains(w)) {
      if (const {'দিন', 'দেন', 'দাও'}.contains(w)) {
        if (_bnNotGive.contains(prev)) return false;
        if (w == fold('দিন') &&
            (_isNumberish(prev) ||
                _bnDayBefore.contains(prev) ||
                _bnDayAfter.contains(next))) {
          return false;
        }
      }
      return true;
    }
    // "শেয়ার করুন", "টাইপ করতে হবে", "টাইপ করে পাঠিয়ে দিন".
    if (_bnCompoundHead.contains(w) && next.startsWith(_bnKor)) return true;
    if (_bnCueInfinitive.contains(w) && _bnCueModal.contains(next)) {
      return true;
    }
    if (w == _bnHowMuch && !_bnHowMuchNotAsk.contains(next)) return true;
    if (_bnWhat.contains(w) &&
        !_bnWhatNotAsk.contains(next) &&
        t.sublist(0, j).any(_bnPossessive.contains)) {
      return true;
    }
    if (_bnWhich.contains(w) && nouns.contains(j + 1)) return true;
    return false;
  }

  static bool _enCue(List<String> t, int j, List<int> nouns) {
    final w = t[j];
    if (w == 'what' || w == 'which') {
      return nouns.contains(j + 1) &&
          !(j + 2 < t.length && _enWhatNotAsk.contains(t[j + 2]));
    }
    final lead = t.sublist(j - 3 < 0 ? 0 : j - 3, j);
    if (_enFirstPersonCues.contains(w)) {
      return lead.any(_enFirstPerson.contains);
    }
    if (!_enCueVerbs.contains(w)) return false;
    if (w == 'read' &&
        !t
            .sublist(j + 1, j + 4 > t.length ? t.length : j + 4)
            .any(_enReadTo.contains)) {
      return false;
    }
    final prev = j > 0 ? t[j - 1] : '';
    final prev2 = j > 1 ? t[j - 2] : '';
    if (t.sublist(0, j).every(_enFillers.contains)) return true;
    if (prev == 'please' || prev == 'kindly') return true;
    if (prev == 'you' && (_enModals.contains(prev2) || prev2 == 'please')) {
      return true;
    }
    if (prev == 'to') {
      return _enToCue.contains(prev2) ||
          t.sublist(0, j).any(_enFirstPerson.contains);
    }
    return false;
  }

  // ------------------------------------------------- "send it" while held

  static RegExp _bnPhrases(List<String> phrases) => RegExp(
    '(?<![\\p{L}\\p{M}])(?:${[for (final p in phrases) RegExp.escape(fold(p))].join('|')})'
    '(?![\\p{L}\\p{M}])',
    unicode: true,
  );

  /// Imperatives: a proceed even with না after ("পাঠিয়ে দিন না").
  static final _proceedBnImperative = _bnPhrases(const [
    'পাঠিয়ে দিন', 'পাঠিয়ে দেন', 'পাঠিয়ে দাও', 'পাঠান', 'পাঠাও', //
    'ছেড়ে দিন', 'ছেড়ে দেন', 'অনুমোদন করুন', 'অনুমোদন দিন', 'অনুমোদন দেন',
    'এগিয়ে যান', 'ট্রান্সফার করুন', 'পেমেন্ট করুন', 'রিলিজ করুন',
    'ছাড় করুন', 'সেন্ড করুন', 'কনফার্ম করুন', 'পাঠিয়ে দেখুন',
    'পাঠিয়ে দেখেন', 'পাঠিয়ে দেখো',
  ]);

  /// "অনুমোদন করে দিন", "সেন্ড করে দিন", "ট্রান্সফার করুন".
  static const _proceedBnHeads = [
    'অনুমোদন', 'অ্যাপ্রুভ', 'এপ্রুভ', 'রিলিজ', 'কনফার্ম', 'সেন্ড', //
    'ট্রান্সফার', 'পেমেন্ট', 'ছাড়',
  ];
  static String get _headsRe =>
      _proceedBnHeads.map((h) => RegExp.escape(fold(h))).join('|');
  static final _proceedBnDo = RegExp(
    '(?<![\\p{L}\\p{M}])(?:$_headsRe)[\\p{L}\\p{M}]*\\s+'
    '(?:${fold('করে')}\\s+(?:${fold('দিন')}|${fold('দেন')}|${fold('দাও')}'
    '|${fold('ফেলুন')})|${fold('করুন')}|${fold('করেন')}|${fold('করো')}'
    '|${fold('দিয়ে')}\\s+${fold('দিন')})(?![\\p{L}\\p{M}])',
    unicode: true,
  );

  /// "অ্যাপ্রুভ বাটনে চাপ দিন".
  static final _proceedBnPress = RegExp(
    '(?<![\\p{L}\\p{M}])(?:$_headsRe)[\\p{L}\\p{M}]*'
    '(?:\\s+[\\p{L}\\p{M}]+){0,2}\\s+(?:${fold('চাপ')}\\s+${fold('দিন')}'
    '|${fold('চাপুন')}|${fold('টিপুন')}|${fold('ট্যাপ')}\\s+${fold('করুন')}'
    '|${fold('ক্লিক')}\\s+${fold('করুন')}|${fold('প্রেস')}\\s+${fold('করুন')})'
    '(?![\\p{L}\\p{M}])',
    unicode: true,
  );

  /// Future forms: a proceed unless না follows ("পাঠাবেন না").
  static final _proceedBnNegatable = _bnPhrases(const [
    'পাঠাবেন', 'পাঠিয়ে দেবেন', 'পাঠিয়ে দিবেন', 'ছেড়ে দেবেন', //
    'অনুমোদন করবেন', 'অনুমোদন দেবেন', 'ট্রান্সফার করবেন', 'পেমেন্ট করবেন',
  ]);

  /// "পাঠাতে পারেন": a proceed unless না follows or the subject is the
  /// trusted person or FinNest.
  static final _proceedBnModal = _bnPhrases(const [
    'পাঠাতে পারেন', 'পাঠাতে পারবেন', 'ছেড়ে দিতে পারেন', //
    'ছেড়ে দিতে পারবেন', 'অনুমোদন দিতে পারেন', 'অনুমোদন দিতে পারবেন',
    'অনুমোদন করতে পারেন', 'অনুমোদন করতে পারবেন', 'এগিয়ে যেতে পারেন',
    'ট্রান্সফার করতে পারেন', 'ট্রান্সফার করতে পারবেন', 'পাঠিয়ে দিতে পারেন',
    'পাঠিয়ে দিতে পারবেন', 'পাঠিয়ে দেখতে পারেন', 'সেন্ড করতে পারেন',
  ]);

  static final _bnNegAfter = RegExp(
    '^\\s*(?:${fold('না')}|${fold('নয়')}|${fold('নি')})(?![\\p{L}\\p{M}])',
    unicode: true,
  );
  static final _bnThirdParty = RegExp(
    '${fold('বিশ্বস্ত')}|${fold('ফিননেস্ট')}|${fold('ব্যাংক')}'
    '|(?<![\\p{L}\\p{M}])(?:${fold('তিনি')}|${fold('উনি')}|${fold('সে')})(?![\\p{L}\\p{M}])',
    unicode: true,
  );
  static final _bnYou = RegExp(
    '(?<![\\p{L}\\p{M}])${fold('আপনি')}(?![\\p{L}\\p{M}])',
    unicode: true,
  );

  static final _proceedEn = RegExp(
    r'\b(?:send|release|approve|transfer|pay|confirm|complete|unlock|unblock|resend|retry)'
    r'\s+(?:it|them|him|her|this|that|now|again'
    r'|(?:the|your)\s+(?:\d[\d,.]*|money|payment|transfer|funds|amount|transaction))\b'
    r'|\bresend\b|\bretry\b'
    r'|\btry\s+(?:sending|paying|transferring|to\s+(?:send|pay|transfer))\b'
    r'|\bgo\s+ahead\b'
    r'|\bcontinue\s+(?:with\s+)?(?:the\s+|your\s+)?(?:payment|transfer|transaction|sending|paying)\b'
    r'|\bcontinue\s+to\s+(?:send|pay|transfer)\b'
    r'|\bproceed\s+with\s+(?:the\s+)?(?:payment|transfer|it)\b',
  );
  static const _enProceedNegation = {
    'not', 'never', 'cannot', "can't", 'cant', "don't", 'dont', "won't", //
    'wont', "shouldn't", 'shouldnt', "mustn't", 'mustnt', "didn't",
    "doesn't", "isn't",
  };
  static const _enModals = {
    'can', 'could', 'may', 'might', 'will', 'would', 'should', 'must', //
    'shall',
  };
  static const _enAdverbs = {
    'now', 'just', 'then', 'also', 'safely', 'simply', 'ever', 'really', //
    'please', 'only',
  };
  static const _enFirstSecond = {'you', 'i', 'we', 'u', 'ya'};
  static const _enThirdParty = {
    'they', 'scammer', 'scammers', 'caller', 'callers', 'someone', 'he', //
    'she', 'fraudster', 'fraudsters', 'people', 'it',
  };
  static final _enWord = RegExp(r"[a-z']+");
  static const _enSubjects = {'you', 'i', 'we', 'he', 'she', 'they', 'u'};
  static const _enTimeLead = {
    'before', 'until', 'till', 'after', 'if', 'when', 'unless', //
  };

  static bool _enProceedAllowed(String before) {
    final w = [for (final m in _enWord.allMatches(before)) m.group(0)!];
    while (w.isNotEmpty && _enAdverbs.contains(w.last)) {
      w.removeLast();
    }
    if (w.isEmpty) return false;
    final last = w.last;
    // "Wait before you send it", "Call your bank before you transfer the
    // money": a time or condition clause, not a go-ahead.
    var subject = w.length - 1;
    if (_enModals.contains(last)) subject--;
    if (subject >= 0 && _enSubjects.contains(w[subject])) {
      for (var b = subject - 1; b >= 0 && b >= subject - 2; b--) {
        if (_enTimeLead.contains(w[b])) return true;
      }
    }
    if (_enProceedNegation.contains(last)) return true;
    if (last == 'to') {
      // "unable to release it", "not allowed to send it"
      for (var b = w.length - 2; b >= 0 && b >= w.length - 4; b--) {
        if (_enProceedNegation.contains(w[b]) || w[b] == 'unable') return true;
      }
      // "They push you to send it back": a scammer's words, described.
      return w.length >= 2 &&
          w[w.length - 2] == 'you' &&
          w.any(_enThirdParty.contains);
    }
    if (const {'and', 'or', 'then'}.contains(last)) {
      // "They can look at a held payment and approve it": the modal and its
      // subject come earlier in the sentence.
      for (var m = w.length - 2; m > 0 && m >= w.length - 9; m--) {
        if (_enModals.contains(w[m])) return !_enFirstSecond.contains(w[m - 1]);
      }
      return false;
    }
    if (_enModals.contains(last)) {
      var s = w.length - 2;
      while (s >= 0 && _enAdverbs.contains(w[s])) {
        s--;
      }
      // "only your trusted person can approve it": not the customer.
      return s >= 0 && !_enFirstSecond.contains(w[s]);
    }
    return false;
  }

  static bool _tellsToProceed(String text) {
    for (final s in _sentence.allMatches(text)) {
      final sentence = s.group(0)!;
      if (_proceedBnImperative.hasMatch(sentence) ||
          _proceedBnDo.hasMatch(sentence) ||
          _proceedBnPress.hasMatch(sentence)) {
        return true;
      }
      for (final m in _proceedBnNegatable.allMatches(sentence)) {
        if (!_bnNegAfter.hasMatch(sentence.substring(m.end))) return true;
      }
      for (final m in _proceedBnModal.allMatches(sentence)) {
        if (_bnNegAfter.hasMatch(sentence.substring(m.end))) continue;
        if (_bnThirdParty.hasMatch(sentence) && !_bnYou.hasMatch(sentence)) {
          continue;
        }
        return true;
      }
      for (final m in _proceedEn.allMatches(sentence)) {
        if (!_enProceedAllowed(sentence.substring(0, m.start))) return true;
      }
    }
    return false;
  }

  // ------------------------------------------ "it is held because ..." (FR-3)

  static final _holdBn = RegExp(
    ['আটক', 'হোল্ড', 'স্থগিত', 'থামানো', 'থামিয়ে', 'থেমে'].map(fold).join('|'),
  );
  static final _holdEn = RegExp(
    r'\b(?:held|hold|holding|stopped|blocked|paused|frozen|delayed|declined)\b',
  );
  static final _notArrivedBn = RegExp(
    ['হয়নি', 'পৌঁছায়নি', 'পৌঁছেনি', 'যায়নি', 'আসেনি'].map(fold).join('|'),
  );
  static final _moneyBn = RegExp(
    ['টাকা', 'লেনদেন', 'পেমেন্ট', 'ট্রান্সফার'].map(fold).join('|'),
  );
  static final _notArrivedEn = RegExp(
    r"\b(?:didn't|did not|has not|hasn't|have not|haven't|not)\s+"
    r'(?:go through|gone through|arrive|arrived|reach|reached|been sent|sent)\b',
  );
  static final _moneyEn = RegExp(r'\b(?:money|payment|transfer|funds)\b');
  static final _reasonBn = RegExp(
    [
      'কারণ',
      'যেহেতু',
      'ফলে',
      'দরুন',
      'হওয়ায়',
      'থাকায়',
      'জন্যই',
    ].map(fold).join('|'),
  );
  static final _reasonEn = RegExp(
    r'\b(?:because|since|due to|owing to|as a result|the reason (?:is|was)|caused by|new payee|risk score)\b'
    r'|\bas\s+(?:the\s+|your\s+|it\s+|this\s+)?(?:new\s+)?(?:payee|recipient|receiver|number|account|amount|risk|risky)\b',
  );

  /// Weaker reason markers, read only in the hold sentence: "নতুন
  /// প্রাপকের জন্য", "তাই আটকে", "so it was held", "held to protect you",
  /// "on hold for a check", "stopped: the receiver ...".
  static final _reason2Bn = RegExp(
    '(?<![\\p{L}\\p{M}])(?:${['জন্য', 'জন্যে', 'তাই', 'সেজন্য', 'সেজন্যই', 'এজন্য'].map(fold).join('|')})(?![\\p{L}\\p{M}])',
    unicode: true,
  );
  static final _reason2En = RegExp(
    r'\bso\b|\bto\s+protect\b|\bin\s+order\s+to\b'
    r'|\bfor\b(?!\s+(?:now|a\s+(?:moment|while|bit)|\d|some\s+time|the\s+moment))'
    r'|:(?!\d)|\s[-–—]\s|—',
  );

  /// Risk words: a hold word with one of these in the same sentence, or in
  /// the next one, explains the hold.
  static final _riskBn = RegExp(
    '(?<![\\p{L}\\p{M}])(?:${['প্রাপক', 'নতুন', 'ঝুঁকি', 'অস্বাভাবিক', 'অংক', 'অঙ্ক', 'প্রতারণা', 'সন্দেহ', 'স্ক্যাম', 'বড়', 'অচেনা', 'রিস্ক'].map(fold).join('|')})',
    unicode: true,
  );
  static final _riskEn = RegExp(
    r'\b(?:risk|risks|risky|payee|recipient|receiver|new|amount|scam|scams'
    r'|fraud|unusual|suspicious|large|big|unknown)\b',
  );

  static bool _isHold(String t) =>
      _holdBn.hasMatch(t) ||
      _holdEn.hasMatch(t) ||
      (_notArrivedBn.hasMatch(t) && _moneyBn.hasMatch(t)) ||
      (_notArrivedEn.hasMatch(t) && _moneyEn.hasMatch(t));

  static bool _risky(String s) => _riskBn.hasMatch(s) || _riskEn.hasMatch(s);

  static final _handoffLines = [
    fold(FnaLines.holdHandoffBn),
    fold(FnaLines.holdHandoffEn),
  ];

  static bool _explainsHold(String text) {
    var t = text;
    for (final line in _handoffLines) {
      t = t.replaceAll(line, ' ');
    }
    if (!_isHold(t)) return false;
    if (_reasonBn.hasMatch(t) || _reasonEn.hasMatch(t)) return true;
    final sentences = [for (final s in _sentence.allMatches(t)) s.group(0)!];
    for (var i = 0; i < sentences.length; i++) {
      final s = sentences[i];
      if (!_isHold(s)) continue;
      if (_reason2Bn.hasMatch(s) || _reason2En.hasMatch(s) || _risky(s)) {
        return true;
      }
      // "The payment was held. The payee is new to you."
      if (i + 1 < sentences.length && _risky(sentences[i + 1])) return true;
    }
    return false;
  }

  // --------------------------------------------------------------- brands

  /// Real banks, mobile-money services, telecom companies and apps FNA must
  /// never name. Real brand names are kept only so the detector can
  /// recognise them. Kept in step with the brand words of the
  /// knowledge base's synonym groups (test). উপায় is left out: it is the
  /// everyday word for "way"; "upay" in Latin letters is in.
  static const brands = [
    'bkash', 'b-kash', 'বিকাশ', 'nagad', 'নগদ', 'rocket', 'রকেট', 'upay', //
    'ইউপে', 'grameenphone', 'grameen phone', 'গ্রামীণফোন', 'গ্রামীণ ফোন',
    'gp', 'জিপি', 'robi', 'রবি', 'banglalink', 'বাংলালিংক', 'airtel',
    'এয়ারটেল', 'teletalk', 'টেলিটক', 'dbbl', 'dutch-bangla', 'dutch bangla',
    'ডাচ-বাংলা', 'ডাচ বাংলা', 'brac', 'ব্র্যাক', 'city bank', 'সিটি ব্যাংক',
    'anydesk', 'এনিডেস্ক', 'teamviewer', 'team viewer', 'টিমভিউয়ার',
    'quicksupport', 'facebook', 'ফেসবুক', 'fb', 'এফবি', 'messenger',
    'মেসেঞ্জার', 'instagram', 'ইনস্টাগ্রাম', 'whatsapp', 'whats app',
    'হোয়াটসঅ্যাপ', 'telegram', 'টেলিগ্রাম', 'imo', 'ইমো', 'viber', 'ভাইবার',
    'daraz', 'দারাজ', 'google', 'গুগল', 'play store', 'প্লে স্টোর',
    'play protect', 'প্লে প্রোটেক্ট', 'বি-কাশ', 'ব্রাক', 'grameen',
    'grameen bank', 'গ্রামীণ ব্যাংক', 'sonali', 'সোনালী ব্যাংক',
    'সোনালি ব্যাংক', 'janata bank', 'জনতা ব্যাংক', 'agrani', 'অগ্রণী ব্যাংক',
    'rupali', 'রূপালী ব্যাংক', 'রূপালি ব্যাংক', 'islami bank',
    'ইসলামী ব্যাংক', 'ইসলামি ব্যাংক', 'pubali', 'পূবালী ব্যাংক',
    'পূবালি ব্যাংক', 'ebl', 'eastern bank', 'ইস্টার্ন ব্যাংক', 'prime bank',
    'প্রাইম ব্যাংক', 'mutual trust', 'mtb', 'মিউচুয়াল ট্রাস্ট', 'pathao',
    'tap app', 'tap wallet', 'tap account', 'trust axiata', 'ট্যাপ অ্যাপ',
    'ট্যাপ অ্যাকাউন্ট', 'ok wallet', 'ওকে ওয়ালেট',
  ];

  static final _bangla = RegExp('[ঀ-৿]');

  static String _brandPattern(String brand) =>
      fold(brand).split(RegExp(r'[\s\-]+')).map(RegExp.escape).join(r'[\s\-]*');

  static final _brandRe = () {
    final latin = <String>[];
    final bangla = <String>[];
    for (final b in brands) {
      if (b == 'নগদ') continue;
      (_bangla.hasMatch(b) ? bangla : latin).add(_brandPattern(b));
    }
    // Bangla takes case endings ("বিকাশে", "রবির"), but "রবিবার" (Sunday)
    // is another word, and "নগদ টাকা" is plain cash.
    final endings = [
      'এর', 'ের', 'ে', 'র', 'য', 'তে', 'কে', 'ও', 'ই', 'েও', 'েই', //
    ].map(fold).join('|');
    const notLetter = r'(?![\p{L}\p{M}])';
    const letterBefore = r'(?<![\p{L}\p{M}])';
    return RegExp(
      '(?<![a-z0-9])(?:${latin.join('|')})(?![a-z0-9])'
      '|$letterBefore(?:${bangla.join('|')})(?:$endings)?$notLetter'
      '|$letterBefore${fold('নগদ')}(?:$endings)?$notLetter'
      '(?!\\s*(?:${fold('টাকা')}|${fold('অর্থ')}))',
      unicode: true,
    );
  }();

  static bool _namesBrand(String text) => _brandRe.hasMatch(text);
}

/// Normalised text and, per code unit, its offset in the original.
class _Norm {
  _Norm(this.text, this.map);

  final String text;
  final List<int> map;
}

/// One number: digits, a number word, or a scale word ("হাজার").
class _El {
  _El(this.start, this.end, this.digits, this.value);

  final int start;
  int end;
  String digits;
  int value;
  bool word = false;
  bool weak = false;
  bool compound = false;
  int scale = 0;
  String sep = '';

  /// The folded number word, while it may still take an English unit
  /// ("forty" + "eight").
  String? w;
}

/// One run of digits and number words.
class _Run {
  _Run(
    this.start,
    this.end,
    this.digits,
    this.groups,
    this.seps, {
    required this.words,
    required this.scaled,
  });

  /// Digits joined; with a scale word, the number read as a whole ("চার
  /// হাজার আটশো একুশ" is 4821).
  factory _Run.of(List<_El> els) {
    final words = els.any((e) => e.word);
    final scaled = els.any((e) => e.scale != 0 || e.compound);
    if (!scaled) {
      return _Run(
        els.first.start,
        els.last.end,
        els.map((e) => e.digits).join(),
        [for (final e in els) e.digits],
        [for (final e in els.skip(1)) e.sep],
        words: words,
        scaled: false,
      );
    }
    var total = 0;
    var current = 0;
    for (final e in els) {
      if (e.scale == 100) {
        current = (current == 0 ? 1 : current) * 100;
      } else if (e.scale != 0) {
        total += (current == 0 ? 1 : current) * e.scale;
        current = 0;
      } else {
        current += e.value;
      }
    }
    final digits = '${total + current}';
    return _Run(
      els.first.start,
      els.last.end,
      digits,
      [digits],
      const [],
      words: words,
      scaled: true,
    );
  }

  final int start;
  final int end;
  final String digits;
  final List<String> groups;
  final List<String> seps;
  final bool words;
  final bool scaled;
}
