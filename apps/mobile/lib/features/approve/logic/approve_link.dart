/// Deep link of a trusted-contact request.
///
/// Two spellings reach the app: the custom scheme registered in the manifest,
/// `bhorosha://approve/<request_id>`, and the https form that an FCM payload
/// or a web fallback may carry, `https://bhorosha.app/approve/<request_id>`.
/// Anything else, and an id that is not `[A-Za-z0-9_-]{1,64}` (empty, too
/// long, or carrying `/`, `?` or `%`-escapes), parses to `null`.
library;

import 'package:bhorosha/app/router.dart';

class ApproveLink {
  const ApproveLink(this.requestId);

  static const scheme = 'bhorosha';
  static const schemeHost = 'approve';
  static const httpsHost = 'bhorosha.app';

  final String requestId;

  static final RegExp _id = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// Server request ids are short tokens; nothing else is ever routed.
  static bool isValidId(String id) => _id.hasMatch(id);

  /// `bhorosha://approve/<id>` or `https://bhorosha.app/approve/<id>`;
  /// `null` for any other URI or an invalid id ([isValidId]).
  static ApproveLink? parse(Uri u) {
    final List<String> segments;
    try {
      segments = u.pathSegments.where((s) => s.isNotEmpty).toList();
    } on FormatException {
      return null; // a malformed %-escape
    }
    final String id;
    switch (u.scheme.toLowerCase()) {
      case scheme:
        if (u.host.toLowerCase() != schemeHost || segments.length != 1) {
          return null;
        }
        id = segments.single;
      case 'https':
        if (u.host.toLowerCase() != httpsHost ||
            segments.length != 2 ||
            segments.first != schemeHost) {
          return null;
        }
        id = segments[1];
      default:
        return null;
    }
    return isValidId(id) ? ApproveLink(id) : null;
  }

  /// Convenience for raw strings; `null` when [raw] is not a URI at all.
  static ApproveLink? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    return uri == null ? null : parse(uri);
  }

  /// The in-app route go_router navigates to.
  String toRoute() => Routes.approveFor(requestId);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApproveLink && requestId == other.requestId;

  @override
  int get hashCode => requestId.hashCode;

  @override
  String toString() => 'ApproveLink($requestId)';
}
