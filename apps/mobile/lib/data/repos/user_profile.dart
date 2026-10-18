import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/persona.dart';

/// The signed-in customer. Mirrors `users/{uid}` in Firestore plus the
/// bundled `balance_bdt` (the seed has no balance).
class UserProfile {
  const UserProfile({
    required this.uid,
    required this.nameBn,
    required this.nameEn,
    required this.phoneMasked,
    required this.persona,
    required this.trustedContactUid,
    required this.p95SendBdt,
    required this.acctId,
    required this.balanceBdt,
    this.district,
  });

  /// Reads the `users/{uid}` shape (snake_case). `persona` defaults to the
  /// uid, `balance_bdt` to 0 (Firestore profiles carry no balance).
  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final uid = requireString(json, 'uid');
    return UserProfile(
      uid: uid,
      nameBn: requireString(json, 'name_bn'),
      nameEn: readString(json, 'name_en', ''),
      phoneMasked: readString(json, 'phone_masked', ''),
      persona: Persona.parse(readString(json, 'persona', uid)),
      trustedContactUid: readString(json, 'trusted_contact_uid', 'rafiq'),
      p95SendBdt: readDouble(json, 'p95_send_bdt', 0),
      acctId: readString(json, 'acct_id', 'acct_$uid'),
      balanceBdt: readDouble(json, 'balance_bdt', 0),
      district: readStringOrNull(json, 'district'),
    );
  }

  final String uid;
  final String nameBn;
  final String nameEn;
  final String phoneMasked;
  final Persona persona;
  final String trustedContactUid;
  final double p95SendBdt;
  final String acctId;
  final double balanceBdt;
  final String? district;

  UserProfile copyWith({double? balanceBdt}) => UserProfile(
    uid: uid,
    nameBn: nameBn,
    nameEn: nameEn,
    phoneMasked: phoneMasked,
    persona: persona,
    trustedContactUid: trustedContactUid,
    p95SendBdt: p95SendBdt,
    acctId: acctId,
    balanceBdt: balanceBdt ?? this.balanceBdt,
    district: district,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'uid': uid,
    'name_bn': nameBn,
    'name_en': nameEn,
    'phone_masked': phoneMasked,
    'persona': persona.uid,
    'trusted_contact_uid': trustedContactUid,
    'p95_send_bdt': p95SendBdt,
    'acct_id': acctId,
    'balance_bdt': balanceBdt,
    'district': district,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserProfile &&
          uid == other.uid &&
          nameBn == other.nameBn &&
          nameEn == other.nameEn &&
          phoneMasked == other.phoneMasked &&
          persona == other.persona &&
          trustedContactUid == other.trustedContactUid &&
          p95SendBdt == other.p95SendBdt &&
          acctId == other.acctId &&
          balanceBdt == other.balanceBdt &&
          district == other.district;

  @override
  int get hashCode => Object.hash(
    uid,
    nameBn,
    nameEn,
    phoneMasked,
    persona,
    trustedContactUid,
    p95SendBdt,
    acctId,
    balanceBdt,
    district,
  );

  @override
  String toString() => 'UserProfile($uid, $nameEn)';
}
