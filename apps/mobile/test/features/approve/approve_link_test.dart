import 'package:bhorosha/features/approve/logic/approve_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApproveLink.parse', () {
    test('accepts the custom scheme form', () {
      final link = ApproveLink.parse(Uri.parse('bhorosha://approve/req-123'));
      expect(link, const ApproveLink('req-123'));
      expect(link!.toRoute(), '/approve/req-123');
    });

    test('accepts the https form', () {
      final link = ApproveLink.parse(
        Uri.parse('https://bhorosha.app/approve/abc-DEF_9'),
      );
      expect(link?.requestId, 'abc-DEF_9');
    });

    test('tolerates a trailing slash and upper-case host', () {
      expect(
        ApproveLink.parse(Uri.parse('bhorosha://APPROVE/req/'))?.requestId,
        'req',
      );
      expect(
        ApproveLink.parse(Uri.parse('HTTPS://Bhorosha.App/approve/req/'))
            ?.requestId,
        'req',
      );
    });

    test('rejects the wrong host', () {
      expect(ApproveLink.parse(Uri.parse('bhorosha://pay/req')), isNull);
      expect(
        ApproveLink.parse(Uri.parse('https://evil.example/approve/req')),
        isNull,
      );
      expect(
        ApproveLink.parse(Uri.parse('https://bhorosha.app/pay/req')),
        isNull,
      );
    });

    test('rejects an empty id', () {
      expect(ApproveLink.parse(Uri.parse('bhorosha://approve')), isNull);
      expect(ApproveLink.parse(Uri.parse('bhorosha://approve/')), isNull);
      expect(
        ApproveLink.parse(Uri.parse('https://bhorosha.app/approve')),
        isNull,
      );
      expect(
        ApproveLink.parse(Uri.parse('https://bhorosha.app/approve/')),
        isNull,
      );
    });

    test('rejects extra segments, http and garbage', () {
      expect(ApproveLink.parse(Uri.parse('bhorosha://approve/a/b')), isNull);
      expect(
        ApproveLink.parse(Uri.parse('https://bhorosha.app/approve/a/b')),
        isNull,
      );
      expect(
        ApproveLink.parse(Uri.parse('http://bhorosha.app/approve/a')),
        isNull,
      );
      expect(ApproveLink.parse(Uri.parse('mailto:a@b.c')), isNull);
      expect(ApproveLink.parse(Uri.parse('not a link')), isNull);
      expect(ApproveLink.parse(Uri()), isNull);
    });

    test('rejects ids outside [A-Za-z0-9_-]{1,64}', () {
      for (final raw in [
        'bhorosha://approve/a%2Fb',
        'bhorosha://approve/a%3Fstate=done',
        'bhorosha://approve/a.b',
        'bhorosha://approve/${'x' * 65}',
        'bhorosha://approve/${'x' * 1024}',
        'bhorosha://approve/abc%zz',
        'https://bhorosha.app/approve/a%2Fb',
      ]) {
        expect(ApproveLink.tryParse(raw), isNull, reason: raw);
      }
      expect(
        ApproveLink.tryParse('bhorosha://approve/${'x' * 64}')?.requestId,
        'x' * 64,
      );
    });

    test('tryParse handles null, empty and malformed strings', () {
      expect(ApproveLink.tryParse(null), isNull);
      expect(ApproveLink.tryParse(''), isNull);
      expect(ApproveLink.tryParse('::::'), isNull);
      expect(ApproveLink.tryParse('bhorosha://approve/x')?.requestId, 'x');
    });
  });
}
