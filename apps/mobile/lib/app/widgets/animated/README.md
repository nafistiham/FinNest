# Animated components

Lively, but calm around money. Every timing comes from `Motion.of(context)`, which is
`BhMotion.of(context)` (`lib/app/theme/motion.dart`, the one motion token source;
`lib/app/motion/motion_specs.dart` only re-exports it as `Motion` / `MotionCurves`). It is
zero when the system asks for reduced motion (`MediaQuery.disableAnimationsOf`).

| Component | Use it for | Motion | Reduce motion |
|---|---|---|---|
| `StaggeredReveal` (motion_specs.dart) | First paint of a list or card stack (Home recents, History) | Fade + rise 8 dp, 240 ms easeOutCubic, 40 ms stagger, max 5 beats, one-shot | Shown at once |
| `RollingAmount` | Any amount that changes on screen | Odometer roll, 600 ms easeOutCubic; leading digits settle first; 1.0 → 1.02 → 1.0 breath; fixed digit slots, static commas; speaks only the final value; shrinks to fit | 120 ms opacity cross-fade, no roll |
| `HeroBalance` (`lib/app/widgets/hero_balance.dart`) | The big balance with no card (Wise style); `AsyncValue` loading / error states, `.value(n)` for a settled amount | 180 ms blur-to-sharp preparation on first show, then `RollingAmount`; eye toggle cross-fades to `৳ • • • • •` | No blur, no roll; cross-fade |
| `SuccessCheck` | A completed, good outcome only | Circle then check draw, 480 ms, small overshoot; `Haptics.success()` + `onDone` at the end | Final frame; haptic and `onDone` still fire |
| `AmountConfirm` | Result "money sent": check, then the amount | `SuccessCheck`, then the amount fades in rolling from 0 | Amount shown at once |
| `Pressable` | Tiles, rows, chips, custom buttons (`selected:` for chips) | 0.97 scale + slight shade, 90 ms in / 150 ms out; focusable, Enter/Space, one button node | Shade only, instant |
| `KeyFeedback` | Wrap numpad keys (72 dp) | Tint to `primaryContainer` 60 % + 0.96 scale, 120 ms; raw pointers only, never steals the key's taps | Fill only, instant |
| `Skeleton`, `SkeletonRow` | Loading rows, cards, the balance (`Skeleton.amount`) | 1.2 s linear shimmer sweep, square corners | Static `surfaceVariant` |
| `StatusPulse` | Safety badge dot, "checking" state | 1.6 s breathing opacity + faint halo while `active`; solid and still when settled | Solid dot |
| `SheetHandleReveal` | Bottom-sheet drag handle | Grows 0 → 32 dp and fades in, a beat after the sheet | Shown at once |
| `SlideFadeIn` | Sheet content, overlay entrance (`scrim:`) | 280 ms slide-up 32 dp + fade; scrim leads. `firm: true` for hold / block: no overshoot | Shown at once |
| `DisplayAmountStyle(context)` | Big numbers | Baloo Da 2 display face (variable, weight 800, both scripts' digits), tight leading (bn 0.95, en 0.9), `onSurface` ink | — |
| `TabularBangla` | Static numbers that must not jitter between values | Fixed slot per digit (widest digit of the script) | — |

Rules:

- Never celebrate a hold or block: no `SuccessCheck`, no overshoot (`SlideFadeIn(firm: true)`),
  no pulsing once a BLOCK verdict has settled.
- Action buttons on an overlay are tappable from the first frame; nothing here blocks hits.
- Colours come from `context.palette` (status colours via `palette.statusText`, brightness-aware).
- There is one `HeroBalance` (`lib/app/widgets/hero_balance.dart`); it composes `Skeleton`,
  `RollingAmount` and `Pressable` from this folder.
