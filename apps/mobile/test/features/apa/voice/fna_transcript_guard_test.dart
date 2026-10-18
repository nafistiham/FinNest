// The transcript guard: codes the customer says or types, and what FNA must
// never say. Bangla and English, with false-positive checks.

import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/app/l10n.dart' show bnDigits;
import 'package:bhorosha/features/apa/knowledge/safety_kb.dart';
import 'package:bhorosha/features/apa/logic/apa_answers.dart';
import 'package:bhorosha/features/apa/logic/apa_helpline.dart';
import 'package:bhorosha/features/apa/voice/fna_instructions.dart';
import 'package:bhorosha/features/apa/voice/fna_transcript_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const guard = FnaTranscriptGuard();

  /// Text that must pass every check: amounts, dates, times, public lines.
  final harmless = [
    '৫০০০ টাকা পাঠিয়েছি',
    'আমার ৫০০০ টাকা আটকে আছে',
    'I sent 5000 taka',
    'Tk 5,000 went out.',
    '৳ ৫,০০০ পাঠিয়েছি',
    '৫,০০০/- কেটে নিয়েছে',
    '5,000 BDT',
    '১০ অক্টোবর কল এসেছিল',
    'at 10:30 today',
    '18/10/2026 তারিখে',
    '২০২৫ সালে',
    '৯৯৯ নম্বরে কল করুন',
    'Call 999 now.',
    '১৬২৩৬ নম্বরে জানান।',
    'ডায়াল করুন *16001#',
    '*১৬০০১#',
    '01320010148 নম্বরে কল করুন।',
    '+880 1320010148',
    '8801320000888',
    '+৮৮০ ১৩২০০০০৮৮৮',
    'হেল্পলাইন ${ApaHelpline.bn} নম্বরে কল করুন।',
    'Call ${ApaHelpline.en}.',
    'Call ${ApaHelpline.en.replaceAll('-', ' ')}.',
    'Call ${ApaHelpline.digits}.',
    '৯৯৯, ১৬২৩৬',
    'রবিবার বিকেলে কল এসেছিল।',
    'one or two calls',
    'এক জন লোক ফোন করে দুই বার বলল',
    'Wait 30 minutes.',
    '',
  ];

  group('one number reader for every path', () {
    for (final said in [
      'আমার কোড ১২৩৪',
      'my otp is 4821',
      'কোড ১ ২ ৩ ৪',
      'pin 12-34',
      'code 12.34',
      'code 1,2,3,4',
      'code 12/34',
      'code (12) 34_56',
      '১২ ৩৪ ৫৬',
      'এক দুই তিন চার',
      'ওটিপি হলো পাঁচ ছয় সাত আট নয়',
      'code is one two three four',
      'শূন্য নয় তিন চার', // nukta spelling of নয় folds
      'এক দুই ৩ ৪', // words and digits mixed
      'বারো চৌত্রিশ', // tens words: 1 2 3 4
      'ছাপ্পান্ন আটচল্লিশ',
      'forty-eight sixteen',
      'forty eight, sixteen',
      'double four seven seven',
      'triple 9 one',
      'ডাবল চার সাত সাত',
      'চার আট দুই নয়',
      '482 916',
      'my code 4829 16',
      '123456',
      'Call 01711223344.',
      '9996',
      '999 1234',
      '16236 99',
      '5000', // a bare number with no money word
      '1234 5000 taka', // not a plain amount shape
    ]) {
      test('"$said" is a code', () {
        expect(guard.checkUser(said), GuardVerdict.secretDigits);
        expect(guard.checkModel(said, held: false), GuardVerdict.digitsEcho);
        final (masked, hit) = FnaTranscriptGuard.redact(said);
        expect(hit, isTrue);
        expect(masked, contains(FnaTranscriptGuard.mask));
        expect(ApaAnswers.redactSecrets(said), (masked, true));
      });
    }

    for (final said in harmless) {
      test('"$said" passes', () {
        expect(guard.checkUser(said), GuardVerdict.ok);
        expect(guard.checkModel(said, held: false), GuardVerdict.ok);
        expect(FnaTranscriptGuard.redact(said), (said, false));
      });
    }

    test('the helpline parts are not allowed on their own', () {
      final parts = ApaHelpline.en.split(RegExp(r'\D+'));
      for (final p in parts.where((p) => p.length >= 4)) {
        if (p == ApaHelpline.digits) continue;
        expect(
          guard.checkModel('Your code is $p', held: false),
          GuardVerdict.digitsEcho,
          reason: p,
        );
        expect(
          guard.checkModel('কোড ${bnDigits(p)}', held: false),
          GuardVerdict.digitsEcho,
        );
      }
    });

    test('a code split over two chunks is caught on the accumulated text', () {
      expect(guard.checkUser('কোড ১২৩'), GuardVerdict.ok);
      expect(
        guard.checkUser(
          'কোড ১২৩'
          '৪',
        ),
        GuardVerdict.secretDigits,
      );
    });

    test('redact keeps the text around the code', () {
      expect(FnaTranscriptGuard.redact('বলল কোড এক দুই তিন চার বলুন'), (
        'বলল কোড •••• বলুন',
        true,
      ));
      expect(FnaTranscriptGuard.redact('pin 4821 and 999'), (
        'pin •••• and 999',
        true,
      ));
    });

    test('extra allowed numbers are exact', () {
      const g = FnaTranscriptGuard(extraAllowedNumbers: {'4821'});
      expect(g.checkModel('4821', held: false), GuardVerdict.ok);
      expect(g.checkModel('48211', held: false), GuardVerdict.digitsEcho);
    });
  });

  group('checkModel: asking for a secret', () {
    for (final said in [
      'আপনার ওটিপি বলুন।',
      'পিনটা দিন।',
      'কোডটা আমাকে বলুন।',
      'কোডটা এখন আমাকে একটু বলুন।',
      'কোডটা বলুন না।', // polite insistence, not a refusal
      'পিন দিন না।',
      'আপনার ওটিপি কত?',
      'আপনার পিন নম্বর কী?',
      'কোডটা আমাকে বলবেন?',
      'কোডটা বলতে পারবেন?',
      'পিন শেয়ার করুন।',
      'আপনার OTP টা বলুন।',
      'Please tell me your PIN.',
      'Share the code with me.',
      'What is your OTP?',
      "What's your PIN?",
      'Tell me your 6-digit code.',
      'Can you read me the OTP?',
      'Type your password here.',
    ]) {
      test('"$said" is an ask', () {
        expect(guard.checkModel(said, held: false), GuardVerdict.secretAsk);
      });
    }

    for (final said in [
      'পিন বা কোড কাউকে বলবেন না।',
      'কোড কাউকে দেবেন না, এফএনএ-কেও না।',
      'কোড কাউকে বলতে পারবেন না।',
      'Never share your PIN with anyone.',
      'Do not tell anyone the code.',
      "Don't give your OTP to a caller.",
      'Never, ever share the code.',
      'কোড চাইলে কল কেটে দিন।',
      'কেউ কোড চাইলে বলবেন না।',
      'কোডের এসএমএস মুছে দিন।',
      'কোড দুই দিন পর আসবে।',
      'ওটিপি কী? এটি একবারের গোপন কোড।',
      'What is an OTP?',
      'What is the OTP scam?',
      'Tell me if anyone asks for your PIN.',
      'FinNest will send you an OTP by SMS.',
    ]) {
      test('"$said" is a warning, not an ask', () {
        expect(guard.checkModel(said, held: false), GuardVerdict.ok);
      });
    }
  });

  group('checkModel: proceed while held', () {
    for (final said in [
      'টাকা পাঠিয়ে দিন।',
      'এখন ছেড়ে দিন।',
      'লেনদেনটি অনুমোদন করুন।',
      'চিন্তা না করে পাঠিয়ে দিন।',
      'টাকা পাঠিয়ে দিন না।',
      'আপনি এখন পাঠাতে পারেন।',
      'আপনি অনুমোদন দিতে পারেন।',
      'You can send it now.',
      'You can now send it.',
      'Go ahead and release it.',
      'Approve the payment.',
      'No problem, send it.',
      'Only you can approve it, so approve it now.',
      'It is fine unless you are worried, release it.',
      // Security review, round 2.
      'Try sending again.',
      'Please resend it.',
      'Pay him now.',
      'Send him the money.',
      'Send the 5000 taka now.',
      'It is fine, continue the transfer.',
      'Go ahead.',
      'You can retry the payment.',
      'টাকাটা পাঠিয়ে দিতে পারেন।',
      'আবার পাঠিয়ে দেখুন।',
      'পেমেন্টটা অনুমোদন করে দিন।',
      'সেন্ড করে দিন।',
      'ট্রান্সফার করে দিন।',
      'অ্যাপ্রুভ বাটনে চাপ দিন।',
    ]) {
      test('"$said" is blocked while held', () {
        expect(
          guard.checkModel(said, held: true),
          GuardVerdict.proceedWhileHeld,
        );
        // The proceed check runs whether or not a payment is held.
        expect(
          guard.checkModel(said, held: false),
          GuardVerdict.proceedWhileHeld,
        );
      });
    }

    for (final said in [
      'টাকা পাঠাবেন না।',
      'আমি টাকা ছেড়ে দিতে পারি না।',
      'শুধু আপনার বিশ্বস্ত মানুষ অনুমোদন দিতে পারেন।',
      'টাকা পাঠানো আটকে আছে।', // "sending is held", not "send"
      'I cannot release it.',
      'I am not able to release it.',
      'Only your trusted person can approve the payment.',
      'Do not send it.',
      'Do not send any money.',
      'They push you to send it back fast.',
      'আটকে থাকা পেমেন্ট তিনি দেখে অনুমোদন দিতে পারেন।',
      FnaLines.holdHandoffBn,
      FnaLines.holdHandoffEn,
    ]) {
      test('"$said" passes while held', () {
        expect(guard.checkModel(said, held: true), GuardVerdict.ok);
        expect(guard.checkModel(said, held: false), GuardVerdict.ok);
      });
    }
  });

  group('checkModel: explaining a hold (FR-3)', () {
    for (final said in [
      'নতুন প্রাপক হওয়ায় আপনার টাকা আটকে আছে।',
      'আপনার টাকা আটকে আছে কারণ আপনি কলে ছিলেন।',
      'টাকা আটকানো হয়েছে। কারণ, প্রাপক নতুন।',
      'যেহেতু অঙ্কটা বড়, পেমেন্ট হোল্ডে আছে।',
      'টাকা পৌঁছায়নি কারণ নম্বরটি নতুন।',
      'Your payment is held because the payee is new.',
      'The transfer was stopped since you were on a call.',
      'It was blocked due to a risky app.',
      'Your money is on hold as the payee is new.',
      "The payment didn't go through because of the risk score.",
      // Security review, round 2.
      'নতুন প্রাপকের জন্য টাকা আটকে আছে।',
      'ঝুঁকিপূর্ণ মনে হয়েছে, তাই আটকে রাখা হয়েছে।',
      'প্রাপক নতুন, তাই পেমেন্ট থেমে আছে।',
      'অস্বাভাবিক বড় অংকের জন্য লেনদেন আটকানো হয়েছে।',
      'This looks like a scam pattern, so it was held.',
      'It was stopped: the receiver looked risky.',
      'The payment was held. The payee is new to you.',
      'on hold for a new recipient check',
      'held to protect you from a likely scam call',
    ]) {
      test('"$said" is blocked while held', () {
        expect(
          guard.checkModel(said, held: true),
          GuardVerdict.holdExplanation,
        );
        expect(guard.checkModel(said, held: false), GuardVerdict.ok);
      });
    }

    for (final said in [
      'আপনার টাকা আটকে আছে কিনা আমি জানি না।',
      'আপনার টাকা আটকে আছে। বিশ্বস্ত মানুষের মত নিন।',
      'Your payment is on hold. The app shows why.',
      FnaLines.holdHandoffBn,
      FnaLines.holdHandoffEn,
      'আপনার টাকা আটকে আছে। ${FnaLines.holdHandoffBn}',
      'Your payment is held. ${FnaLines.holdHandoffEn}',
      'আপনার কোনো টাকা এখন আটকে নেই।',
    ]) {
      test('"$said" passes while held', () {
        expect(guard.checkModel(said, held: true), GuardVerdict.ok);
      });
    }
  });

  group('checkModel: brand names', () {
    for (final said in [
      'বিকাশে টাকা পাঠাবেন না।',
      'নগদ অ্যাপে কোড আসে।',
      'রবির নম্বর থেকে কল।',
      'রবি থেকে এসএমএস এসেছে।',
      'গ্রামীণফোন কখনো পিন চায় না।',
      'Do not install AnyDesk.',
      'Someone on WhatsApp asked for money.',
      'Use the bKash app.',
      'Dutch-Bangla Bank never calls.',
      'City Bank will not call you.',
      'ফেসবুকে লিংক এসেছে।',
      'ইমোতে কল এসেছে।',
      'Play Store থেকে অ্যাপ নামান।',
    ]) {
      test('"$said" names a brand', () {
        expect(guard.checkModel(said, held: false), GuardVerdict.brandName);
      });
    }

    for (final said in [
      'রবিবার বিকেলে কল এসেছিল।',
      'রবিবারে অফিস বন্ধ।',
      'নগদ টাকা কাউকে দেবেন না।',
      'কোনো উপায় নেই, হেল্পলাইনে কল করুন।',
      'একটি মোবাইল ব্যাংকিং কোম্পানি কখনো কোড চায় না।',
      'A mobile-money company never asks for your PIN.',
      'In my opinion, call the helpline.',
    ]) {
      test('"$said" passes', () {
        expect(guard.checkModel(said, held: false), GuardVerdict.ok);
      });
    }

    // The knowledge base names no private business, so the names customers
    // say are listed here. Real brand names are kept only so the detector
    // can recognise them.
    const namedByCustomers = [
      'bkash', 'বিকাশ', 'nagad', 'rocket', 'রকেট', 'upay', 'grameenphone', //
      'গ্রামীণফোন', 'gp', 'robi', 'রবি', 'banglalink', 'বাংলালিংক', 'airtel',
      'এয়ারটেল', 'teletalk', 'টেলিটক', 'anydesk', 'এনিডেস্ক', 'teamviewer',
      'টিমভিউয়ার', 'quicksupport', 'facebook', 'ফেসবুক', 'fb', 'messenger',
      'মেসেঞ্জার', 'instagram', 'ইনস্টাগ্রাম', 'whatsapp', 'হোয়াটসঅ্যাপ',
      'telegram', 'টেলিগ্রাম', 'imo', 'ইমো', 'viber', 'ভাইবার', 'daraz',
      'দারাজ', 'play protect', 'প্লে প্রোটেক্ট', 'play store', 'প্লে স্টোর',
      'google', 'গুগল', 'dbbl', 'dutch-bangla',
    ];

    for (final word in namedByCustomers) {
      test('"$word" is a private business name', () {
        expect(
          guard.checkModel('এটা $word নিয়ে।', held: false),
          GuardVerdict.brandName,
          reason: word,
        );
      });
    }

    // Public agencies may be named.
    for (final said in [
      'বাংলাদেশ ব্যাংকের ১৬২৩৬ নম্বরে জানান।',
      'সিআইডির সাইবার অভিযোগ নম্বরে জানান।',
      'Contact Bangladesh Bank on 16236.',
      'Report it to the CID.',
      'BTRC says to dial *16001#.',
      'বিপদে থাকলে ৯৯৯-এ ফোন করুন।',
    ]) {
      test('"$said" names a public agency and passes', () {
        expect(guard.checkModel(said, held: false), GuardVerdict.ok);
      });
    }
  });

  test('every knowledge base text passes the guard', () {
    final kb = SafetyKnowledgeBase.parse(
      File(SafetyKnowledgeBase.assetPath).readAsStringSync(),
    );
    for (final c in kb.chunks) {
      for (final english in [false, true]) {
        final text = kb.textOf(c, english: english);
        expect(
          guard.checkModel(text, held: false),
          GuardVerdict.ok,
          reason: '${c.id}: $text',
        );
        // Sentence by sentence too, so one safe sentence cannot hide
        // another.
        for (final sentence in text.split(RegExp(r'(?<=[.!?।])\s+'))) {
          expect(
            guard.checkModel(sentence, held: false),
            GuardVerdict.ok,
            reason: '${c.id}: $sentence',
          );
        }
      }
    }
  });

  test('the fixed lines pass', () {
    for (final line in [
      FnaLines.dontKnowBn,
      FnaLines.dontKnowEn,
      FnaLines.holdHandoffBn,
      FnaLines.holdHandoffEn,
    ]) {
      expect(guard.checkModel(line, held: true), GuardVerdict.ok);
    }
  });

  group('security review, round 2: codes', () {
    void flagged(String said) {
      expect(guard.checkUser(said), GuardVerdict.secretDigits, reason: said);
      // FNA saying it is caught as an echo (or, with a secret word and a
      // request verb, as an ask).
      expect(
        guard.checkModel(said, held: false),
        isNot(GuardVerdict.ok),
        reason: said,
      );
      final (masked, hit) = FnaTranscriptGuard.redact(said);
      expect(hit, isTrue, reason: said);
      expect(masked, contains(FnaTranscriptGuard.mask), reason: said);
      expect(ApaAnswers.redactSecrets(said), (masked, true));
    }

    // Finding 1: spoken forms.
    for (final said in [
      'ফোর এইট টু ওয়ান',
      'ওয়ান টু থ্রি ফোর',
      'জিরো ওয়ান টু থ্রি ফোর ফাইভ সিক্স সেভেন এইট নাইন',
      'এক দু তিন চার',
      'ছ সাত আট নয়',
      'এক দুই তিন ন',
      'char ath dui ek',
      'ek dui tin char',
      'panch choy saat aat noy',
      'shunno noi pach chhoy',
      'চার হাজার আটশো একুশ',
      'four thousand eight hundred twenty one',
      'এক হাজার দুশো চৌত্রিশ',
      'নয় হাজার নশো',
    ]) {
      test('"$said" is a code', () => flagged(said));
    }

    test('a spoken number with hundreds is read as a whole', () {
      expect(FnaTranscriptGuard.redact('কোড চার হাজার আটশো একুশ বললাম'), (
        'কোড ${FnaTranscriptGuard.mask} বললাম',
        true,
      ));
      expect(
        FnaTranscriptGuard.redact(
          'the number four thousand eight hundred twenty one',
        ),
        ('the number ${FnaTranscriptGuard.mask}', true),
      );
    });

    // Finding 2: invisible characters, other digits, odd separators.
    for (final said in [
      '১‍২‍৩‍৪',
      '1​2​3​4',
      '1⁠234',
      '12­34',
      '1🙂2🙂3🙂4',
      '１２３４',
      '٤٨٢١',
      '۴۸۲۱',
      '४८२१',
      '¹²³⁴',
      '𝟒𝟖𝟐𝟏',
      '1*2*3*4',
      '1:2:3:4',
      '1+2+3+4',
      '1|2|3|4',
      '1;2;3;4',
      '12\n34',
      '1    2 3 4',
      '1 - 2 - 3 - 4',
    ]) {
      test('${jsonEncode(said)} is a code', () => flagged(said));
    }

    test('the mask covers the invisible characters inside the code', () {
      expect(FnaTranscriptGuard.redact('কোড ১‍২‍৩‍৪ এসেছে'), (
        'কোড ${FnaTranscriptGuard.mask} এসেছে',
        true,
      ));
      expect(FnaTranscriptGuard.redact('pin 𝟒𝟖𝟐𝟏 ok'), (
        'pin ${FnaTranscriptGuard.mask} ok',
        true,
      ));
      expect(FnaTranscriptGuard.maskDigits('কোড ٤٨'), 'কোড ••');
    });

    // Finding 3: a secret word before the number beats the money word.
    for (final said in [
      'কোড ৪৮২১৯৩ টাকা পাঠাতে লাগবে',
      'ওটিপি ৪৮২১ টাকা ফেরতের জন্য',
      'the code 482193 tk refund',
      'my pin 2025',
      'OTP 12:34',
      'পিন ৫০০০ পাঠাব',
    ]) {
      test('"$said" is a code', () => flagged(said));
    }

    // Finding 11: a public number repeated with only a space.
    for (final said in ['999 999', '৯৯৯ ৯৯৯', '16236 16236']) {
      test('"$said" is a code', () => flagged(said));
    }

    // Finding 12, and what must keep passing.
    for (final said in [
      'আমি ৫০০০ পাঠাব, নিরাপদ?',
      'Can I send 15000 to my brother?',
      'I paid 12000 yesterday.',
      'In 2025 I lost money',
      '১৯৯৮ সালে',
      'দুই হাজার পঁচিশ সালে',
      'পাঁচ হাজার টাকা পাঠিয়েছি',
      'five thousand taka',
      'হাজার হাজার মানুষ',
      'at 10:30 today',
      '১০:৩০ এ কল এসেছিল',
      '18/10/2026',
      '৯৯৯ বা ১৬২৩৬',
      '999 or 16236',
      '৯৯৯ / ১৬২৩৬',
      'দু জন লোক ফোন করেছিল',
      'আমি না বলেছি, ন না',
      'I sat at the table at 10.',
      'He is in his teen years, no char.',
      '50% 100 টাকা',
      'ফোর জি নেটওয়ার্ক',
    ]) {
      test('"$said" passes', () {
        expect(guard.checkUser(said), GuardVerdict.ok);
        expect(guard.checkModel(said, held: false), GuardVerdict.ok);
        expect(FnaTranscriptGuard.redact(said), (said, false));
      });
    }
  });

  group('security review, round 2: asking for a secret', () {
    for (final said in [
      'Tell me OTP.',
      'Please type OTP here.',
      'Kindly provide OTP to verify.',
      'I need your OTP to help.',
      'May I have your PIN?',
      'Please let me know your PIN.',
      'Could you tell me what code you got?',
      'Which code did you receive?',
      'Read out the six digits in the SMS.',
      'You have to share your OTP.',
      'Don\'t worry, tell me the code.',
      'আপনার ওটিপি কত ছিল?',
      'ওটিপি কত এসেছে?',
      'আপনার পিন কী এখন?',
      'ওটিপি কোডটা শেয়ার করতে পারবেন?',
      'ওটিপি কোডটা টাইপ করতে হবে।',
      'কোডটা একবার এখানে টাইপ করে পাঠিয়ে দিন।',
      'আপনার পিনটা জানতে চাই।',
      'আপনার ওটিপিটা আমার লাগবে।',
      'মেসেজে আসা সংখ্যাগুলো বলুন।',
      'কোন কোড এসেছে?',
    ]) {
      test('"$said" is an ask', () {
        expect(guard.checkModel(said, held: false), GuardVerdict.secretAsk);
      });
    }

    for (final said in [
      'পিন বা কোড কাউকে বলবেন না।',
      'Never share your PIN or OTP with anyone.',
      'প্রতারক ফোন করে ওটিপি চায়।',
      'A real agent never asks for your PIN.',
      'কোড বলে ফেললে এখনই হেল্পলাইনে ফোন করুন।',
      'If you shared your OTP, call the helpline now.',
      'ওটিপি আর পিন এক জিনিস নয়।',
      'Your PIN stays the same until you change it.',
      'They will tell you to share your PIN.',
      'Change your PIN in the app now.',
      'Do not scan QR codes from unknown ads.',
      'কোডের মেয়াদ কত মিনিট থাকে তা এসএমএসে লেখা থাকে।',
    ]) {
      test('"$said" is advice, not an ask', () {
        expect(guard.checkModel(said, held: false), GuardVerdict.ok);
      });
    }
  });

  group('security review, round 2: brands', () {
    for (final said in [
      'Sonali Bank never calls.',
      'Janata Bank will not ask.',
      'Agrani or Rupali staff never call.',
      'Islami Bank, Pubali and EBL never call.',
      'Eastern Bank and Prime Bank never call.',
      'Mutual Trust never calls.',
      'City Bank and BRAC never call.',
      'ব্রাক ব্যাংক থেকে কল এসেছে।',
      'Dutch-Bangla never calls.',
      'Pathao Pay never asks.',
      'Open the Tap app.',
      'OK Wallet never calls.',
      'বি-কাশ থেকে কল।',
      'বি কাশে টাকা পাঠাবেন না।',
      'গ্রামীনফোন কখনো পিন চায় না।',
      'সোনালী ব্যাংকে যান।',
      'বি‌কাশ', // a ZWNJ inside the name
    ]) {
      test('"$said" names a brand', () {
        expect(guard.checkModel(said, held: false), GuardVerdict.brandName);
      });
    }

    for (final said in [
      'রবিবার বিকেলে কল এসেছিল।',
      'নগদ টাকা কাউকে দেবেন না।',
      'কোনো উপায় নেই, হেল্পলাইনে কল করুন।',
      'Do not tap the link.',
      'গ্রামীণ এলাকায় এমন কল বেশি আসে।',
      'জনতার ভিড়ে ফোন সাবধানে রাখুন।',
    ]) {
      test('"$said" passes', () {
        expect(guard.checkModel(said, held: false), GuardVerdict.ok);
      });
    }
  });

  group('security review, round 2: links', () {
    for (final said in [
      'Open https://evil.example/x now.',
      'Go to evil.example now.',
      'Visit bit.ly/abc',
      'evil.com/login',
      'evil (dot) com',
      'evil[.]com',
      'evil dot com',
      'hxxps://evil.example',
      'https[:]//evil.example',
      'evil。com',
      'www.evil.net',
      'ইভিল ডট কম',
      'e​vil.c​om',
    ]) {
      test('"$said" is a link', () {
        expect(FnaTranscriptGuard.hasLink(said), isTrue);
        expect(guard.checkModel(said, held: false), GuardVerdict.link);
        expect(FnaTranscriptGuard.maskLinks(said), contains('[link]'));
      });
    }

    for (final said in [
      'e.g. call the helpline.',
      'Tk 5.00 was cut.',
      'Click the red dot now.',
      'Call 999. Then wait.',
    ]) {
      test('"$said" is not a link', () {
        expect(FnaTranscriptGuard.hasLink(said), isFalse);
      });
    }
  });

  group('streaming, before-you-send, setting a PIN', () {
    GuardVerdict streamed(List<String> chunks) {
      var text = '';
      for (final c in chunks) {
        text += c;
        final v = guard.checkModel(text, held: true, partial: true);
        if (v != GuardVerdict.ok) return v;
      }
      return guard.checkModel(text, held: true);
    }

    test('a last word the next chunk negates does not block', () {
      expect(streamed(['যাচাই না করে টাকা পাঠাবেন', ' না।']), GuardVerdict.ok);
      expect(streamed(['কাউকে আপনার পিন বলবেন', ' না।']), GuardVerdict.ok);
      expect(streamed(['You can', ' not send it yet.']), GuardVerdict.ok);
    });

    test('an open last word is judged when the turn completes', () {
      expect(
        guard.checkModel(
          'যাচাই না করে টাকা পাঠাবেন',
          held: true,
          partial: true,
        ),
        GuardVerdict.ok,
      );
      expect(
        guard.checkModel('যাচাই না করে টাকা পাঠাবেন', held: true),
        GuardVerdict.proceedWhileHeld,
      );
      expect(
        guard.checkModel('কাউকে আপনার পিন বলবেন', held: false, partial: true),
        GuardVerdict.ok,
      );
      expect(
        guard.checkModel('কাউকে আপনার পিন বলবেন', held: false),
        GuardVerdict.secretAsk,
      );
    });

    test('a complete or imperative proceed still blocks while streaming', () {
      expect(
        streamed(['টাকা পাঠিয়ে', ' দিন।']),
        GuardVerdict.proceedWhileHeld,
      );
      expect(
        guard.checkModel('টাকা পাঠিয়ে দিন', held: true, partial: true),
        GuardVerdict.proceedWhileHeld,
      );
      expect(
        guard.checkModel(
          'ঠিক আছে। টাকা পাঠাবেন। তারপর',
          held: true,
          partial: true,
        ),
        GuardVerdict.proceedWhileHeld,
      );
      expect(
        guard.checkModel('আপনার কোড বলুন', held: false, partial: true),
        GuardVerdict.secretAsk,
      );
    });

    test('"before you send it" is a time clause, not a go-ahead', () {
      for (final said in [
        'Wait before you send it.',
        'Hang up and call your trusted person before you send it.',
        'Check with your trusted person before you pay them.',
        'Call your bank before you transfer the money.',
      ]) {
        expect(
          guard.checkModel(said, held: true),
          GuardVerdict.ok,
          reason: said,
        );
      }
      for (final said in [
        'Send it now.',
        'You can send it now.',
        'Go ahead and pay him.',
        'আগে যাচাই করুন, তারপর পাঠান',
      ]) {
        expect(
          guard.checkModel(said, held: true),
          GuardVerdict.proceedWhileHeld,
          reason: said,
        );
      }
    });

    test('changing or setting a PIN is advice, not an ask', () {
      for (final said in [
        'আপনার পিন রিসেট করতে হবে।',
        'পাসওয়ার্ড পরিবর্তন করতে হবে।',
        'পিন পরিবর্তন করতে পারেন সেটিংস থেকে।',
        'এখনই নতুন পাসওয়ার্ড দিন।',
        'আপনার পিন বদলে নতুন পিন দিন।',
        'You can type your PIN only inside the FinNest app.',
      ]) {
        expect(
          guard.checkModel(said, held: false),
          GuardVerdict.ok,
          reason: said,
        );
      }
      for (final said in [
        'আপনার পিন শেয়ার করতে হবে।',
        'কোডটা টাইপ করতে হবে।',
        'আপনার পিন বলুন।',
        'You can tell me your PIN in the app.',
        'Please type your PIN here.',
      ]) {
        expect(
          guard.checkModel(said, held: false),
          GuardVerdict.secretAsk,
          reason: said,
        );
      }
    });
  });

  group('maskDigits', () {
    test('code-like runs are hidden, public numbers stay', () {
      expect(FnaTranscriptGuard.maskDigits('কোড ১২৩৪'), 'কোড ••••');
      expect(FnaTranscriptGuard.maskDigits('pin 12-34'), 'pin ••••');
      expect(FnaTranscriptGuard.maskDigits('my code 4829 16'), 'my code ••••');
      expect(
        FnaTranscriptGuard.maskDigits('কোড এক দুই তিন চার বললাম'),
        'কোড •••• বললাম',
      );
      expect(FnaTranscriptGuard.maskDigits('কোনো নম্বর নেই'), 'কোনো নম্বর নেই');
      // A piece of a code still arriving shows no digits either.
      expect(FnaTranscriptGuard.maskDigits('কোড ১২'), 'কোড ••');
      expect(FnaTranscriptGuard.maskDigits('৪৮২'), '•••');
      expect(FnaTranscriptGuard.maskDigits('এক দুই'), 'এক দুই');
      for (final keep in [
        '৯৯৯ নম্বরে কল করুন',
        'Call 999 now.',
        'হেল্পলাইন ${ApaHelpline.bn} নম্বরে কল করুন।',
        'Call ${ApaHelpline.en}.',
        'ডায়াল করুন *16001#',
        '01320010148',
        '+880 1320010148',
        '01320000888',
        '+880 1320000888',
        '১৬২৩৬',
        '৫০০০ টাকা',
      ]) {
        expect(FnaTranscriptGuard.maskDigits(keep), keep);
      }
    });
  });
}
