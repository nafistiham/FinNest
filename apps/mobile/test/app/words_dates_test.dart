import 'package:bhorosha/app/dates.dart';
import 'package:bhorosha/app/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('takaInWords (South Asian system, 9.1)', () {
    const table = <int, (String, String)>{
      0: ('শূন্য টাকা', 'zero taka'),
      1: ('এক টাকা', 'one taka'),
      19: ('উনিশ টাকা', 'nineteen taka'),
      21: ('একুশ টাকা', 'twenty-one taka'),
      99: ('নিরানব্বই টাকা', 'ninety-nine taka'),
      100: ('একশো টাকা', 'one hundred taka'),
      1000: ('এক হাজার টাকা', 'one thousand taka'),
      5000: ('পাঁচ হাজার টাকা', 'five thousand taka'),
      7900: ('সাত হাজার নয়শো টাকা', 'seven thousand nine hundred taka'),
      100000: ('এক লাখ টাকা', 'one lakh taka'),
      120000: ('এক লাখ বিশ হাজার টাকা', 'one lakh twenty thousand taka'),
      1234567: (
        'বারো লাখ চৌত্রিশ হাজার পাঁচশো সাতষট্টি টাকা',
        'twelve lakh thirty-four thousand five hundred sixty-seven taka',
      ),
      23456789: (
        'দুই কোটি চৌত্রিশ লাখ ছাপ্পান্ন হাজার সাতশো ঊননব্বই টাকা',
        'two crore thirty-four lakh fifty-six thousand seven hundred eighty-nine taka',
      ),
    };
    table.forEach((n, words) {
      test('$n', () {
        expect(takaInWords(n, bangla: true), words.$1);
        expect(takaInWords(n, bangla: false), words.$2);
      });
    });
  });

  group('BhDates (Asia/Dhaka, 9.4)', () {
    // 2026-11-11 12:30 in Dhaka = 06:30 UTC.
    final now = DateTime.utc(2026, 11, 11, 6, 30);
    const bn = Locale('bn');
    const en = Locale('en');

    test('today shows the part of the day and the time', () {
      final ts = DateTime.utc(2026, 11, 11, 6, 30);
      expect(BhDates.rowLabel(ts, bn, now: now), 'আজ, দুপুর ১২:৩০');
      expect(BhDates.rowLabel(ts, en, now: now), 'Today, 12:30 pm');
      expect(BhDates.dayHeader(ts, bn, now: now), 'আজ');
    });

    test('yesterday, same year and other years', () {
      expect(
        BhDates.rowLabel(DateTime.utc(2026, 11, 10, 6), bn, now: now),
        'গতকাল',
      );
      expect(
        BhDates.rowLabel(DateTime.utc(2026, 11, 1, 6), bn, now: now),
        '১ নভে.',
      );
      expect(
        BhDates.rowLabel(DateTime.utc(2026, 11, 1, 6), en, now: now),
        '1 Nov',
      );
      expect(
        BhDates.rowLabel(DateTime.utc(2025, 11, 10, 6), bn, now: now),
        '১০ নভে. ২০২৫',
      );
      expect(
        BhDates.dayHeader(DateTime.utc(2026, 10, 25, 6), bn, now: now),
        '২৫ অক্টোবর',
      );
    });

    test('the Dhaka day boundary, not UTC, decides "today"', () {
      // 19:00 UTC on the 10th is 01:00 on the 11th in Dhaka.
      final late = DateTime.utc(2026, 11, 10, 19);
      expect(BhDates.daysAgo(late, now), 0);
      expect(BhDates.time(late, bn), 'রাত ১:০০');
    });

    test('parts of the day', () {
      expect(BhDates.partOfDay(4), 'ভোর');
      expect(BhDates.partOfDay(6), 'সকাল');
      expect(BhDates.partOfDay(12), 'দুপুর');
      expect(BhDates.partOfDay(16), 'বিকাল');
      expect(BhDates.partOfDay(18), 'সন্ধ্যা');
      expect(BhDates.partOfDay(20), 'রাত');
      expect(BhDates.partOfDay(3), 'রাত');
    });

    test('month and year', () {
      expect(
        BhDates.monthYear(DateTime.utc(2026, 9, 15), bn),
        'সেপ্টেম্বর ২০২৬',
      );
      expect(
        BhDates.monthYear(DateTime.utc(2026, 9, 15), en),
        'September 2026',
      );
    });
  });
}
