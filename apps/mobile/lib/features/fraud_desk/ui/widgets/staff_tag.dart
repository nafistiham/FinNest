/// The persistent "স্টাফ ভিউ · ডেমো" tag of every Fraud desk screen (info).
library;

import 'package:flutter/material.dart';

import '../../../../app/l10n.dart';
import '../../../../app/theme/theme.dart';
import '../../../../app/widgets/status_tag.dart';

class StaffTag extends StatelessWidget {
  const StaffTag({super.key});

  static const tagKey = Key('fraud_desk_staff_tag');

  @override
  Widget build(BuildContext context) => StatusTag(
    key: tagKey,
    label: context.l10n.fraudDeskStaffTag,
    status: BhStatus.info,
  );
}
