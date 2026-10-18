import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';

export '../l10n/app_localizations.dart';

extension L10nX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  /// Whether numbers show in Bangla digits: every locale but English. Bangla
  /// when there is no `Localizations` above (a bare widget test).
  bool get banglaDigits =>
      Localizations.maybeLocaleOf(this)?.languageCode != 'en';

  /// [s] with its digits in the active style: Bangla digits for `bn`, Latin
  /// digits for `en` (either kind in, the right kind out).
  String digits(String s) => banglaDigits ? bnDigits(s) : asciiDigits(s);

  /// A taka amount with lakh grouping in the active digits:
  /// `৳ ৫,০০০` in Bangla, `৳ 5,000` in English.
  String taka(num amount) => formatTaka(amount, bangla: banglaDigits);

  /// The English form of a name when the app is in English and one exists,
  /// otherwise the Bangla one (names are data, not ARB strings).
  String localName(String bn, String? en) =>
      !banglaDigits && en != null && en.trim().isNotEmpty ? en : bn;
}

/// Server copy (FR-3) in the app language: every risk-mw text travels as a
/// `*_bn` / `*_en` pair, and the app only picks the field, never writes one.
extension ServerTextX on BuildContext {
  /// [en] when the app is in English and [en] is non-empty, else [bn]; falls
  /// back to whichever of the two is non-empty. Bangla when there is no
  /// `Localizations` above (a bare widget test).
  String serverText(String bn, String en) => pickServerText(
    Localizations.maybeLocaleOf(this) ?? const Locale('bn'),
    bn,
    en,
  );
}

/// The provider-free form of [ServerTextX.serverText] for logic code:
/// English [locale] prefers [en], every other locale prefers [bn], and an
/// empty (or blank) preferred field falls back to the other one.
String pickServerText(Locale locale, String bn, String en) {
  final preferEn = locale.languageCode == 'en';
  final first = preferEn ? en : bn;
  final second = preferEn ? bn : en;
  return first.trim().isNotEmpty ? first : second;
}

const _bnDigits = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];

/// Replaces every ASCII digit with its Bangla digit. Other characters pass through.
String bnDigits(String s) {
  final out = StringBuffer();
  for (final rune in s.runes) {
    if (rune >= 0x30 && rune <= 0x39) {
      out.write(_bnDigits[rune - 0x30]);
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

/// The inverse of [bnDigits]: every Bangla digit becomes its ASCII digit.
String asciiDigits(String s) {
  final out = StringBuffer();
  for (final rune in s.runes) {
    final i = _bnDigits.indexOf(String.fromCharCode(rune));
    if (i >= 0) {
      out.write(i);
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

/// A record id as a customer-facing reference: its last six letters and
/// digits (dashes, underscores and the rest dropped), uppercased ASCII.
/// A reference is a code, not a number, so its digits never follow the
/// locale: `txn_9f3a2c464c1` -> `C464C1` in both languages.
String referenceCode(String id) {
  final clean = asciiDigits(id).replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  final tail = clean.length <= 6 ? clean : clean.substring(clean.length - 6);
  return tail.toUpperCase();
}

/// Groups an integer amount the Bangladeshi way: the last three digits, then
/// pairs. 5000 -> '5,000'; 50000 -> '50,000'; 100000 -> '1,00,000';
/// 12345678 -> '1,23,45,678'. Fractions are dropped (taka amounts in this app
/// are whole).
String groupLakh(num amount) {
  final negative = amount < 0;
  final digits = amount.abs().round().toString();
  if (digits.length <= 3) {
    return negative ? '-$digits' : digits;
  }
  final last3 = digits.substring(digits.length - 3);
  var head = digits.substring(0, digits.length - 3);
  final parts = <String>[];
  while (head.length > 2) {
    parts.insert(0, head.substring(head.length - 2));
    head = head.substring(0, head.length - 2);
  }
  parts.insert(0, head);
  final grouped = '${parts.join(',')},$last3';
  return negative ? '-$grouped' : grouped;
}

/// '৳ ৫,০০০' in Bangla (default) or '৳ 5,000' in English.
String formatTaka(num amount, {bool bangla = true}) {
  final grouped = groupLakh(amount);
  return '৳ ${bangla ? bnDigits(grouped) : grouped}';
}

/// Words for 0..99 in Bangla. Bangla number words are irregular (৩৯ is
/// "ঊনচল্লিশ", not "ত্রিশ নয়"), so they come from a table, never composed.
const _bnWords = [
  'শূন্য', 'এক', 'দুই', 'তিন', 'চার', 'পাঁচ', 'ছয়', 'সাত', 'আট', 'নয়', //
  'দশ',
  'এগারো',
  'বারো',
  'তেরো',
  'চৌদ্দ',
  'পনেরো',
  'ষোলো',
  'সতেরো',
  'আঠারো',
  'উনিশ',
  'বিশ',
  'একুশ',
  'বাইশ',
  'তেইশ',
  'চব্বিশ',
  'পঁচিশ',
  'ছাব্বিশ',
  'সাতাশ',
  'আটাশ',
  'ঊনত্রিশ',
  'ত্রিশ',
  'একত্রিশ',
  'বত্রিশ',
  'তেত্রিশ',
  'চৌত্রিশ',
  'পঁয়ত্রিশ',
  'ছত্রিশ',
  'সাঁইত্রিশ',
  'আটত্রিশ',
  'ঊনচল্লিশ',
  'চল্লিশ',
  'একচল্লিশ',
  'বিয়াল্লিশ',
  'তেতাল্লিশ',
  'চুয়াল্লিশ',
  'পঁয়তাল্লিশ',
  'ছেচল্লিশ',
  'সাতচল্লিশ',
  'আটচল্লিশ',
  'ঊনপঞ্চাশ',
  'পঞ্চাশ',
  'একান্ন',
  'বাহান্ন',
  'তিপ্পান্ন',
  'চুয়ান্ন',
  'পঞ্চান্ন',
  'ছাপ্পান্ন',
  'সাতান্ন',
  'আটান্ন',
  'ঊনষাট',
  'ষাট',
  'একষট্টি',
  'বাষট্টি',
  'তেষট্টি',
  'চৌষট্টি',
  'পঁয়ষট্টি',
  'ছেষট্টি',
  'সাতষট্টি',
  'আটষট্টি',
  'ঊনসত্তর',
  'সত্তর',
  'একাত্তর',
  'বাহাত্তর',
  'তিয়াত্তর',
  'চুয়াত্তর',
  'পঁচাত্তর',
  'ছিয়াত্তর',
  'সাতাত্তর',
  'আটাত্তর',
  'ঊনআশি',
  'আশি',
  'একাশি',
  'বিরাশি',
  'তিরাশি',
  'চুরাশি',
  'পঁচাশি',
  'ছিয়াশি',
  'সাতাশি',
  'আটাশি',
  'ঊননব্বই',
  'নব্বই',
  'একানব্বই',
  'বিরানব্বই',
  'তিরানব্বই',
  'চুরানব্বই',
  'পঁচানব্বই',
  'ছিয়ানব্বই',
  'সাতানব্বই',
  'আটানব্বই',
  'নিরানব্বই',
];

const _enOnes = [
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', //
  'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
  'sixteen', 'seventeen', 'eighteen', 'nineteen',
];
const _enTens = [
  '', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', //
  'eighty', 'ninety',
];

String _enBelow100(int n) {
  if (n < 20) return _enOnes[n];
  final t = _enTens[n ~/ 10];
  return n % 10 == 0 ? t : '$t-${_enOnes[n % 10]}';
}

/// [n] (> 0) in words, South Asian grouping: কোটি / লাখ / হাজার / শো.
String _numberWords(int n, {required bool bangla}) {
  final parts = <String>[];
  final crore = n ~/ 10000000;
  var rest = n % 10000000;
  if (crore > 0) {
    parts
      ..add(_numberWords(crore, bangla: bangla))
      ..add(bangla ? 'কোটি' : 'crore');
  }
  final lakh = rest ~/ 100000;
  rest %= 100000;
  final thousand = rest ~/ 1000;
  rest %= 1000;
  final hundred = rest ~/ 100;
  final below = rest % 100;
  String w(int k) => bangla ? _bnWords[k] : _enBelow100(k);
  if (lakh > 0) parts.addAll([w(lakh), bangla ? 'লাখ' : 'lakh']);
  if (thousand > 0) parts.addAll([w(thousand), bangla ? 'হাজার' : 'thousand']);
  if (hundred > 0) {
    parts.add(bangla ? '${_bnWords[hundred]}শো' : '${w(hundred)} hundred');
  }
  if (below > 0) parts.add(w(below));
  return parts.join(' ');
}

/// A whole taka amount in words, for the line under the big number on the
/// PIN and approve screens: 120000 -> "এক লাখ বিশ
/// হাজার টাকা" / "one lakh twenty thousand taka". Negative amounts use
/// their absolute value; fractions are dropped.
String takaInWords(int amount, {required bool bangla}) {
  final n = amount.abs();
  final words = n == 0
      ? (bangla ? _bnWords[0] : _enOnes[0])
      : _numberWords(n, bangla: bangla);
  return '$words ${bangla ? 'টাকা' : 'taka'}';
}

extension TakaWordsX on BuildContext {
  /// [takaInWords] in the active language.
  String takaWords(int amount) => takaInWords(amount, bangla: banglaDigits);
}

extension TakaSpokenX on BuildContext {
  /// An amount as TalkBack and Apa say it: the word after the number,
  /// "৫,০০০ টাকা" / "5,000 taka" (never "৳" in spoken text, 9.1).
  String takaSpoken(num amount) =>
      '${digits(groupLakh(amount))} ${banglaDigits ? 'টাকা' : 'taka'}';
}
