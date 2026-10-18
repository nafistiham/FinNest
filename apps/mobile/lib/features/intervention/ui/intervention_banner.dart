import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n.dart';
import '../../../app/server_text.dart';
import '../../../app/theme/theme.dart';
import '../../../app/widgets/brand_glyph.dart';
import '../../../core/haptics.dart';
import '../../../core/log.dart';
import '../../../data/contracts/intervene.dart';
import '../../../data/contracts/score.dart';
import '../logic/action_labels.dart';
import '../logic/apa_voice.dart';
import '../logic/asset_catalog.dart';
import 'intervention_style.dart';

const _tag = 'banner';

/// The clip `/v1/intervene` chose for a delay, queued after the predicted one
/// when it differs. [scriptBn] is the TTS fallback for an unknown id.
typedef ServedClip = ({String? assetId, String scriptBn});

/// The banner container for `delay` and `step_up`: a
/// caution-coloured card with the same inputs as the overlay. Renders, in
/// this order of preference, [script] (the stored `script_bn`/`script_en`
/// picked for the app language by the caller, e.g. `record.script(context)`),
/// else [intervene]'s script in the app language, else the reasons
/// ([reasons] when given, e.g. the stored record's, else the score's);
/// buttons are labelled from `actions[].type` (FR-3).
/// The card is the decision's container colour (a dark tint in dark mode)
/// with a 4 dp stripe; text on it uses the matching `on...Container`.
///
/// On its first frame it fires the `warning()` haptic of the 6.3 map and, when
/// [servedClip] names a clip other than [predictedAsset], queues it.
class InterventionBanner extends ConsumerStatefulWidget {
  const InterventionBanner({
    super.key,
    required this.score,
    required this.intervene,
    required this.actions,
    required this.onAction,
    required this.onDismiss,
    this.script,
    this.reasons,
    this.servedClip,
    this.predictedAsset,
    this.trustedSent = false,
    this.trustedBusy = false,
    this.english = false,
    this.haptics = const SystemHaptics(),
  });

  final ScoreResponse score;
  final InterveneResponse? intervene;

  /// The server script already picked for the app language (the stored
  /// record's `script(context)`); shown above everything when non-empty.
  final String? script;

  /// The reasons to show when there is no script; the score's when null.
  final List<Reason>? reasons;

  /// The served clip to queue once, when its id differs from [predictedAsset].
  final ServedClip? servedClip;

  /// The clip the caller already queued from the score alone.
  final String? predictedAsset;
  final List<ActionItem> actions;
  final void Function(ActionItem) onAction;
  final VoidCallback onDismiss;

  /// The trusted-contact request went out: its button becomes
  /// [TrustedRequestSentLine] in place.
  final bool trustedSent;

  /// The trusted-contact request is in flight: its button is disabled.
  final bool trustedBusy;

  /// The UI is English: the lines are spoken in English (no Bangla clip).
  final bool english;
  final Haptics haptics;

  @override
  ConsumerState<InterventionBanner> createState() => _InterventionBannerState();
}

class _InterventionBannerState extends ConsumerState<InterventionBanner> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.haptics.warning());
    // The same voice stack as the hold overlay: the server's lines through ApaVoice (bundled
    // clip, server clip, live audio, Gemini TTS), never the phone's own
    // voice: the predicted clip already played in the assistant's voice.
    final voice = ref.read(apaVoiceProvider);
    final lines = widget.intervene?.lines ?? const <ApaLine>[];
    if (lines.isNotEmpty) {
      for (final line in lines) {
        if (!widget.english &&
            AssetCatalog.idForScript(line.textBn) == widget.predictedAsset) {
          continue;
        }
        unawaited(
          voice.speak(
            ApaUtterance.fromLine(
              line,
              fallback: ApaFallback.none,
              english: widget.english,
            ),
          ),
        );
      }
      return;
    }
    final clip = widget.servedClip;
    if (clip == null) return;
    final id = clip.assetId;
    if (id == null || (!widget.english && id == widget.predictedAsset)) return;
    Log.d(_tag, 'served asset "$id" differs from predicted; queued after it');
    unawaited(
      voice.speak(
        ApaUtterance(
          textBn: clip.scriptBn,
          textEn: widget.intervene?.scriptEn ?? '',
          assetId: id,
          fallback: ApaFallback.none,
          english: widget.english,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = Theme.of(context).textTheme;
    final style = InterventionStyle.of(context, widget.score.decision);
    final ink = style.onContainer;
    final stored = widget.script?.trim() ?? '';
    final script = stored.isNotEmpty
        ? stored
        : widget.intervene?.script(context).trim() ?? '';
    final reasons = widget.reasons ?? widget.score.reasons;

    return Container(
      key: const ValueKey('intervention_banner'),
      decoration: BoxDecoration(
        color: style.container,
        border: Border(
          left: BorderSide(color: style.fill, width: BhSize.stripe),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        BhSpace.m - BhSize.stripe,
        BhSpace.m,
        BhSpace.m,
        BhSpace.m,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const BrandGlyph(size: BhSize.avatarSmall),
              const SizedBox(width: BhSpace.m),
              Expanded(
                child: Text(
                  style.title,
                  style: text.titleMedium?.copyWith(color: ink),
                ),
              ),
              TextButton(
                key: const ValueKey('banner_dismiss'),
                style: TextButton.styleFrom(
                  foregroundColor: ink,
                  minimumSize: const Size(BhSize.touch, BhSize.touch),
                ),
                onPressed: widget.onDismiss,
                child: Text(l10n.interventionDismiss),
              ),
            ],
          ),
          const SizedBox(height: BhSpace.m),
          if (script.isNotEmpty)
            Text(
              script,
              key: const ValueKey('banner_script'),
              style: context.textRoles.script.copyWith(color: ink),
            )
          else
            for (final r in uniqueReasons(context, reasons))
              Padding(
                padding: const EdgeInsets.only(bottom: BhSpace.s),
                child: ReasonLine(
                  text: r.text(context),
                  color: style.fill,
                  style: text.bodyLarge?.copyWith(color: ink),
                ),
              ),
          const SizedBox(height: BhSpace.m),
          for (final a in orderForThumbZone(widget.actions)) ...[
            if (a.type == ActionLabels.trustedContactCheck)
              if (widget.trustedSent)
                const TrustedRequestSentLine()
              else
                ActionButton(
                  action: a,
                  busy: widget.trustedBusy,
                  onPressed: () => widget.onAction(a),
                )
            else
              ActionButton(action: a, onPressed: () => widget.onAction(a)),
            const SizedBox(height: BhSpace.s),
          ],
        ],
      ),
    );
  }
}

/// Shows an [InterventionBanner] floating above the current screen's bottom
/// edge (thumb zone) as an overlay entry, so the PIN screen underneath stays
/// put. Returns a closer; [onDismiss] closes the banner and then runs the
/// caller's callback. Actions do not close it: the caller decides.
VoidCallback showInterventionBanner(
  BuildContext context, {
  required ScoreResponse score,
  required InterveneResponse? intervene,
  required List<ActionItem> actions,
  required void Function(ActionItem) onAction,
  required VoidCallback onDismiss,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  var closed = false;
  void close() {
    if (closed) return;
    closed = true;
    entry.remove();
  }

  entry = OverlayEntry(
    builder: (_) => Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(BhSpace.m),
          child: Material(
            type: MaterialType.transparency,
            child: InterventionBanner(
              english: Localizations.localeOf(context).languageCode == 'en',
              score: score,
              intervene: intervene,
              actions: actions,
              onAction: onAction,
              onDismiss: () {
                close();
                onDismiss();
              },
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  return close;
}
