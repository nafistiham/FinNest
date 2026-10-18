/// Dates and times as a Bangladeshi customer reads them:
/// Gregorian calendar, Bangla month names and digits in `bn`, English in
/// `en`, Asia/Dhaka (UTC+6, no DST) for display whatever the phone's zone.
///
/// Rows:   "আজ, দুপুর ১২:৩০" · "গতকাল" · "১০ নভে." · "১০ নভে. ২০২৫"
/// Headers: "আজ" · "গতকাল" · "১০ নভেম্বর" · "১০ নভেম্বর ২০২৫"
library;

import 'package:flutter/widgets.dart';

import 'l10n.dart';

abstract final class BhDates {
  static const dhakaOffset = Duration(hours: 6);

  static const _bnMonths = [
    'জানুয়ারি', 'ফেব্রুয়ারি', 'মার্চ', 'এপ্রিল', 'মে', 'জুন', //
    'জুলাই', 'আগস্ট', 'সেপ্টেম্বর', 'অক্টোবর', 'নভেম্বর', 'ডিসেম্বর',
  ];
  static const _bnShort = [
    'জানু.', 'ফেব্রু.', 'মার্চ', 'এপ্রিল', 'মে', 'জুন', //
    'জুলাই', 'আগ.', 'সেপ্টে.', 'অক্টো.', 'নভে.', 'ডিসে.',
  ];
  static const _enMonths = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July', //
    'August', 'September', 'October', 'November', 'December',
  ];
  static const _enShort = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', //
    'Nov', 'Dec',
  ];

  static bool _bn(Locale locale) => locale.languageCode != 'en';

  /// [ts] as wall-clock time in Dhaka (a UTC `DateTime` whose fields read
  /// as Dhaka time).
  static DateTime dhaka(DateTime ts) => ts.toUtc().add(dhakaOffset);

  static DateTime _day(DateTime d) => DateTime.utc(d.year, d.month, d.day);

  /// 0 for today, 1 for yesterday, negative for the future.
  static int daysAgo(DateTime ts, DateTime now) =>
      _day(dhaka(now)).difference(_day(dhaka(ts))).inDays;

  static String _digits(Locale locale, String s) =>
      _bn(locale) ? bnDigits(s) : s;

  /// "দুপুর ১২:৩০" / "12:30 pm". Bangla names the part of the day instead
  /// of am/pm: ভোর 4-5, সকাল 6-11, দুপুর 12-15, বিকাল 16-17, সন্ধ্যা 18-19,
  /// রাত 20-3.
  static String time(DateTime ts, Locale locale) {
    final d = dhaka(ts);
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final clock = '$h12:${d.minute.toString().padLeft(2, '0')}';
    if (!_bn(locale)) return '$clock ${d.hour < 12 ? 'am' : 'pm'}';
    return '${partOfDay(d.hour)} ${bnDigits(clock)}';
  }

  /// The Bangla part of the day for an hour 0..23.
  static String partOfDay(int hour) {
    if (hour >= 4 && hour < 6) return 'ভোর';
    if (hour >= 6 && hour < 12) return 'সকাল';
    if (hour >= 12 && hour < 16) return 'দুপুর';
    if (hour >= 16 && hour < 18) return 'বিকাল';
    if (hour >= 18 && hour < 20) return 'সন্ধ্যা';
    return 'রাত';
  }

  static String _date(DateTime ts, Locale locale, DateTime now, bool short) {
    final d = dhaka(ts);
    final bn = _bn(locale);
    final m = d.month - 1;
    final month = bn
        ? (short ? _bnShort[m] : _bnMonths[m])
        : (short ? _enShort[m] : _enMonths[m]);
    final sameYear = d.year == dhaka(now).year;
    final s = sameYear ? '${d.day} $month' : '${d.day} $month ${d.year}';
    return _digits(locale, s);
  }

  /// Row subtitle date: today with the time, then "গতকাল", then the short
  /// date (year only when it is not this year).
  static String rowLabel(DateTime ts, Locale locale, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final l10n = lookupAppLocalizations(
      _bn(locale) ? const Locale('bn') : const Locale('en'),
    );
    return switch (daysAgo(ts, n)) {
      0 => '${l10n.today}, ${time(ts, locale)}',
      1 => l10n.yesterday,
      _ => _date(ts, locale, n, true),
    };
  }

  /// Group header in History: "আজ", "গতকাল", else the full date.
  static String dayHeader(DateTime ts, Locale locale, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final l10n = lookupAppLocalizations(
      _bn(locale) ? const Locale('bn') : const Locale('en'),
    );
    return switch (daysAgo(ts, n)) {
      0 => l10n.today,
      1 => l10n.yesterday,
      _ => _date(ts, locale, n, false),
    };
  }

  /// "১০ নভে." / "10 Nov" (year when not this year), no today/yesterday.
  static String shortDate(DateTime ts, Locale locale, {DateTime? now}) =>
      _date(ts, locale, now ?? DateTime.now(), true);

  /// "২৫ অক্টোবর" / "25 October" (year when not this year).
  static String longDate(DateTime ts, Locale locale, {DateTime? now}) =>
      _date(ts, locale, now ?? DateTime.now(), false);

  /// "১০ নভেম্বর, ১৪:১৩" / "10 November, 14:13" for a wall-clock [wall]
  /// that is already Dhaka time (a server's "2026-11-10 14:13:00"): no zone
  /// shift, 24-hour clock, the year only when it is not [now]'s year.
  static String wallDayTime(
    DateTime wall,
    Locale locale, {
    bool withTime = true,
    DateTime? now,
  }) {
    final bn = _bn(locale);
    final month = (bn ? _bnMonths : _enMonths)[wall.month - 1];
    final year = (now ?? DateTime.now()).year == wall.year
        ? ''
        : ' ${wall.year}';
    final day = '${wall.day} $month$year';
    final clock =
        '${wall.hour.toString().padLeft(2, '0')}:'
        '${wall.minute.toString().padLeft(2, '0')}';
    return _digits(locale, withTime ? '$day, $clock' : day);
  }

  /// "সেপ্টেম্বর ২০২৬" / "September 2026" (bill month).
  static String monthYear(DateTime ts, Locale locale) {
    final d = dhaka(ts);
    final bn = _bn(locale);
    final month = bn ? _bnMonths[d.month - 1] : _enMonths[d.month - 1];
    return _digits(locale, '$month ${d.year}');
  }
}
