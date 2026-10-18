# FinNest tokens in the Flutter app

This page maps each token group in `tokens.json` to the Dart code that holds the same value, so the
two never drift. The shared widgets are in `lib/app/widgets/`.

All paths are under `apps/mobile/`.

| `tokens.json` group | Dart source | Constant / accessor in widgets |
|---|---|---|
| `color.light.*`, `color.dark.*` (brand part) | `lib/app/theme/palette.dart`, `_brand[BhPreset.teal]` (`$1` light, `$2` dark) | `context.palette.primary`, `.onPrimary`, `.primaryContainer`, `.onPrimaryContainer`, `.accent`, `.surface`, `.surfaceVariant`, `.onSurface`, `.mutedText`, `.outline`, `.outlineVariant` |
| `color.light.*`, `color.dark.*` (status part) | `palette.dart`, `_statusLight` / `_statusDark`; fills in the `_Status` getters (`dangerFill` …, same in both modes) | `context.palette.danger`, `.dangerFill`, `.onDangerFill`, `.dangerContainer`, `.onDangerContainer` (same for `warning`, `success`; `info`, `infoContainer`, `onInfoContainer`); by meaning: `palette.statusText(BhStatus.x)`, `statusContainer`, `onStatusContainer`, `statusFill` |
| `color.*.brandLeaf`, `brandNavy` | `palette.dart`, getters `brandLeaf`, `brandNavy` | `context.palette.brandLeaf` / `.brandNavy` (wordmark only, `BrandWordmark` in `lib/app/widgets/brand_mark.dart`) |
| `color.brand.iconBackground` | `tool/make_brand_assets.py`, `OFF_WHITE_HEX` | Android `values/colors.xml` (`ic_launcher_background`, `launch_background`), generated |
| `color.preset.<name>` | `palette.dart`, `_brand[BhPreset.<name>]`; enum `BhPreset` (`teal` is `BhPreset.fallback`) | Chosen in Settings (`themePresetProvider`, `lib/app/appearance.dart`), applied by `buildTheme(brightness, preset:)` |
| `status.*` | the same palette fields, grouped by meaning | `BhStatus` enum (`danger`, `warning`, `success`, `info`, `neutral`); `StatusTag` widget |
| `font.family.bangla` / `latin` | `lib/app/theme/typography.dart`, `BhType.family`, `familyFor`, `fallbackFor` | Set by `buildTheme` from the locale |
| `font.family.display`, `typography.display.*` | `lib/app/widgets/animated/expressive_text.dart`, `DisplayAmountStyle` (`family`, `weight`, line height, tracking); hero size `HeroBalance.amountSize` in `lib/app/widgets/hero_balance.dart` | `DisplayAmountStyle(context, size: …)` |
| `typography.bn.*`, `typography.en.*` (Material roles) | `typography.dart`, `BhType.textTheme` (`if (bn)` table, then the Latin table) | `Theme.of(context).textTheme.bodyMedium` etc. |
| `typography.*.amountHero`, `amountEntry`, `amountEntryCompact`, `numpadDigit`, `numberEntry`, `pinDigitCounter`, `script` | `typography.dart`, `BhType.roles` | `context.textRoles.amountHero` etc. |
| `space.*` | `lib/app/theme/tokens.dart`, `BhSpace` | `BhSpace.m` |
| `size.*` | `tokens.dart`, `BhSize` | `BhSize.touch` |
| `radius.none` | `lib/app/theme/theme.dart`, `_square` (`BorderRadius.zero`) | Already applied to every Material component by `buildTheme` |
| `border.*`, `elevation.none` | `theme.dart` (`BorderSide(width: 2)`, `DividerThemeData(thickness: 1)`, `elevation: 0`), `BhSize.stripe` | Theme components |
| `motion.duration.*` | `lib/app/theme/motion.dart`, `BhMotion.standard` (`BhMotion.none` = reduced motion); `BhMotion.crossfade` | `BhMotion.of(context).normal` (also re-exported as `Motion` in `lib/app/motion/motion_specs.dart`) |
| `motion.easing.*` | `motion.dart`, `BhCurves` | `BhCurves.enter` (`MotionCurves`) |
| Fonts | `assets/fonts/` (`SolaimanLipi.ttf`, `SolaimanLipiBold.ttf`, `BalooDa2-Variable.ttf`), declared in `pubspec.yaml` | `web/fonts/` holds byte-identical copies |
| Mark | `assets/brand/finnest_logo.png` (from `tool/make_brand_assets.py`) | `assets/finnest-mark.png` here is a copy |

Legacy: `BhColors` in `tokens.dart` still carries deprecated teal-light constants and the
`colorScheme.dangerText / okText / cautionText` accessors; they resolve to the palette values above.
New code uses `context.palette`.

## Keeping them in sync

```bash
python3 design-system/tools/sync.py check    # ok, or names what drifted
python3 design-system/tools/sync.py tokens   # after changing a value in Dart
python3 design-system/tools/sync.py web      # then regenerate the CSS and Tailwind files
```

The script reads the Dart files above with regular expressions; if you restructure one of them
(rename `_statusLight`, move `BhSpace`), update `tools/sync.py` in the same PR. If you copy new font
files into the app, copy them into `web/fonts/` too.
