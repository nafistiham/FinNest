import 'package:bhorosha/app/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bnDigits', () {
    test('replaces every ASCII digit and keeps punctuation', () {
      expect(bnDigits('5,000'), '৫,০০০');
      expect(bnDigits('017XXXXX412'), '০১৭XXXXX৪১২');
      expect(bnDigits('no digits'), 'no digits');
    });
  });

  group('groupLakh', () {
    test('uses Bangladeshi grouping', () {
      expect(groupLakh(0), '0');
      expect(groupLakh(999), '999');
      expect(groupLakh(5000), '5,000');
      expect(groupLakh(50000), '50,000');
      expect(groupLakh(100000), '1,00,000');
      expect(groupLakh(12345678), '1,23,45,678');
      expect(groupLakh(-7900), '-7,900');
    });

    test('rounds fractions away', () {
      expect(groupLakh(5000.4), '5,000');
    });
  });

  group('formatTaka', () {
    test('Bangla by default, English on request', () {
      expect(formatTaka(5000), '৳ ৫,০০০');
      expect(formatTaka(100000), '৳ ১,০০,০০০');
      expect(formatTaka(5000, bangla: false), '৳ 5,000');
    });
  });
}
