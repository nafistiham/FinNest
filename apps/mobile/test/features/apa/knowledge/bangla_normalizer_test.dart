import 'package:bhorosha/features/apa/knowledge/bangla_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fold', () {
    // (input, expected, rule) golden pairs, one or more per fold rule.
    const golden = <(String, String, String)>[
      ('ড়', 'ড', 'precomposed ড় to ড'),
      ('ড়', 'ড', 'decomposed ড় to ড'),
      ('ঢ়', 'ঢ', 'precomposed ঢ় to ঢ'),
      ('ঢ়', 'ঢ', 'decomposed ঢ় to ঢ'),
      ('য়', 'য', 'precomposed য় to য'),
      ('য়', 'য', 'decomposed য় to য'),
      ('কো', 'কো', 'ে + া to ো'),
      ('কৌ', 'কৌ', 'ে + ৗ to ৌ'),
      ('উত্‍স', 'উৎস', 'khanda ta'),
      ('উৎস', 'উৎস', 'khanda ta kept'),
      ('র‌্যাব', 'র্যাব', 'ZWNJ removed'),
      ('র‍্যাব', 'র্যাব', 'ZWJ removed'),
      ('নীল', 'নিল', 'ী to ি'),
      ('দূর', 'দুর', 'ূ to ু'),
      ('৯৯৯', '999', 'Bengali digits'),
      ('০১২৩৪৫৬৭৮৯', '0123456789', 'all ten digits'),
      ('OTP PIN', 'otp pin', 'Latin lowercase'),
      ('না।', 'না ', 'dari'),
      ('হ্যাঁ॥', 'হ্যাঁ ', 'double dari'),
      ('ok?!', 'ok  ', 'ASCII punctuation'),
    ];
    for (final (input, expected, rule) in golden) {
      test(rule, () => expect(BanglaNormalizer.fold(input), expected));
    }

    test('both nukta forms fold to the same word', () {
      expect(
        BanglaNormalizer.fold('টাকা পাঠিয়েছে'),
        BanglaNormalizer.fold('টাকা পাঠিয়েছে'),
      );
    });

    test('is idempotent', () {
      const s = 'কোড চাইলে কী করব? ৯৯৯ নম্বর থেকে OTP।';
      final once = BanglaNormalizer.fold(s);
      expect(BanglaNormalizer.fold(once), once);
    });
  });

  group('tokens', () {
    test('keeps Bangla words whole across vowel signs', () {
      expect(BanglaNormalizer.tokens('কোড চাইলে কী করব?'), [
        'কোড',
        'চাইলে',
        'কি',
        'করব',
      ]);
    });

    test('keeps conjuncts and the hasant inside a word', () {
      expect(BanglaNormalizer.tokens('অ্যাপ স্ক্রিন শেয়ার'), [
        'অ্যাপ',
        'স্ক্রিন',
        'শেযার',
      ]);
    });

    test('maps digits to ASCII', () {
      expect(BanglaNormalizer.tokens('*১৬০০১# ডায়াল'), ['16001', 'ডাযাল']);
    });

    test('splits mixed Banglish on punctuation and spaces', () {
      expect(BanglaNormalizer.tokens('FinNest-এ OTP দিলাম, ok!'), [
        'finnest',
        'এ',
        'otp',
        'দিলাম',
        'ok',
      ]);
    });

    test('empty and punctuation-only input give no tokens', () {
      expect(BanglaNormalizer.tokens(''), isEmpty);
      expect(BanglaNormalizer.tokens(' ।॥?! '), isEmpty);
    });
  });

  group('trigrams', () {
    test('pads with the boundary marker', () {
      expect(BanglaNormalizer.trigrams('otp'), ['#ot', 'otp', 'tp#']);
    });

    test('a one-letter token gives one trigram', () {
      expect(BanglaNormalizer.trigrams('a'), ['#a#']);
    });

    test('an empty token gives none', () {
      expect(BanglaNormalizer.trigrams(''), isEmpty);
    });

    test('works on Bangla code units', () {
      expect(BanglaNormalizer.trigrams('পিন'), ['#পি', 'পিন', 'িন#']);
    });
  });
}
