/// `/v1/actions/trusted-contact` request, response and decision
/// (contracts.py).
library;

import 'package:bhorosha/data/contracts/common.dart';

/// `class TrustedContactRequest(Strict)`.
class TrustedContactRequest {
  const TrustedContactRequest({
    required this.interventionId,
    required this.contactUid,
  });

  factory TrustedContactRequest.fromJson(Map<String, dynamic> json) =>
      TrustedContactRequest(
        interventionId: requireString(json, 'intervention_id'),
        contactUid: requireString(json, 'contact_uid'),
      );

  final String interventionId;
  final String contactUid;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'intervention_id': interventionId,
    'contact_uid': contactUid,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrustedContactRequest &&
          interventionId == other.interventionId &&
          contactUid == other.contactUid;

  @override
  int get hashCode => Object.hash(interventionId, contactUid);

  @override
  String toString() => 'TrustedContactRequest(${toJson()})';
}

/// `class TrustedContactResponse(Strict)`; `expires_at` is an ISO-8601 string.
class TrustedContactResponse {
  const TrustedContactResponse({
    required this.requestId,
    required this.expiresAt,
  });

  factory TrustedContactResponse.fromJson(Map<String, dynamic> json) =>
      TrustedContactResponse(
        requestId: requireString(json, 'request_id'),
        expiresAt: requireString(json, 'expires_at'),
      );

  final String requestId;
  final String expiresAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'request_id': requestId,
    'expires_at': expiresAt,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrustedContactResponse &&
          requestId == other.requestId &&
          expiresAt == other.expiresAt;

  @override
  int get hashCode => Object.hash(requestId, expiresAt);

  @override
  String toString() => 'TrustedContactResponse(${toJson()})';
}

/// `class TrustedContactDecision(Strict)`.
///
/// [status] is `approved|declined|expired|pending` on the wire (see the
/// `status*` constants); the plan keeps it as a string.
class TrustedContactDecision {
  const TrustedContactDecision({
    required this.requestId,
    required this.status,
    this.decidedBy,
    this.contactVerified,
  });

  factory TrustedContactDecision.fromJson(Map<String, dynamic> json) =>
      TrustedContactDecision(
        requestId: requireString(json, 'request_id'),
        status: requireString(json, 'status'),
        decidedBy: readStringOrNull(json, 'decided_by'),
        contactVerified: readBoolOrNull(json, 'contact_verified'),
      );

  static const String statusApproved = 'approved';
  static const String statusDeclined = 'declined';
  static const String statusExpired = 'expired';
  static const String statusPending = 'pending';

  final String requestId;
  final String status;

  /// Additive field: the uid that settled the request; null while
  /// pending or once it expired unanswered.
  final String? decidedBy;

  /// Additive field: whether [decidedBy] is the named trusted contact.
  /// Always true with auth on (anyone else is refused); in demo mode anyone
  /// may decide and `false` says it was not the contact. Null while pending,
  /// after an unanswered expiry, or from an older server.
  final bool? contactVerified;

  /// The server says someone other than the contact decided: the app keeps
  /// the hold and shows "not confirmed by your trusted person".
  bool get notByContact => contactVerified == false;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'request_id': requestId,
    'status': status,
    'decided_by': decidedBy,
    'contact_verified': contactVerified,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrustedContactDecision &&
          requestId == other.requestId &&
          status == other.status &&
          decidedBy == other.decidedBy &&
          contactVerified == other.contactVerified;

  @override
  int get hashCode =>
      Object.hash(requestId, status, decidedBy, contactVerified);

  @override
  String toString() => 'TrustedContactDecision(${toJson()})';
}
