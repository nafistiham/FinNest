/// The last `ScoreResponse` the Apa sheet opens with.
///
/// This is the same provider the PIN screen writes after every score
/// (`lastScoreProvider` in the send-money feature), re-exported under the
/// name the Apa feature uses so the held-transaction first line is always
/// built from the most recent server reasons.
library;

import 'package:bhorosha/features/send_money/logic/risk_providers.dart';

/// `null` until a transaction has been scored this session.
final apaHeldScoreProvider = lastScoreProvider;
