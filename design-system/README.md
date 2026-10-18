# FinNest design system

FinNest (ফিননেস্ট) is a fictional Bangladeshi digital bank built for the Google Cloud AI Builder Cup 2026.
Its guide is **FinNest Assistant** (ফিননেস্ট সহকারী), short **FNA** (এফএনএ). The customers are people
like Rina (28, garment worker, first-time smartphone owner) and Rahima (67, Bhola): one hand, a mid-range
Android phone, bad light, low literacy, constant interruption. Every rule here comes from that.

This folder is the brand-level source of truth for every surface: the Flutter Android app
(`apps/mobile`), the operator console (`apps/console`), and any web page, deck or video
frame. It is platform-neutral; the platform files apply it.

| File | What it is |
|---|---|
| `README.md` | This document: the rules in prose |
| `tokens.json` | Every value, machine-readable (W3C Design Tokens format), each quoting the Dart constant it mirrors |
| `web/finnest.css` | CSS custom properties (light, dark, presets, bn/en type scale, reduced motion), `@font-face`, opt-in base components |
| `web/finnest.tailwind.js` | Tailwind preset over the same CSS variables |
| `web/demo.html` | Palette, type, buttons, tags and an amount on one page; open it in a browser to eyeball changes |
| `web/fonts/` | SolaimanLipi 400/700, Baloo Da 2 variable, their licences |
| `assets/finnest-mark.png` | The mark, transparent, 512 px (copy of the app's `assets/brand/finnest_logo.png`) |
| `flutter.md` | Where each token lives in the Flutter code |
| `tools/sync.py` | `tokens` (Dart → tokens.json), `web` (tokens.json → CSS, Tailwind), `check` (fails on drift) |

Values are quoted from the Flutter theme, which is where they were tuned on a real phone. To change one:
edit the Dart constant, run `python3 design-system/tools/sync.py tokens && python3 design-system/tools/sync.py web`
from the repository root, and commit all of it. `python3 design-system/tools/sync.py check` must print `ok`
before a design change merges.

---

## 1. Identity

### Name

| | Bangla | English |
|---|---|---|
| Product | ফিননেস্ট | FinNest |
| Assistant, titles and first mention on a surface | ফিননেস্ট সহকারী | FinNest Assistant |
| Assistant, buttons, chips, captions | এফএনএ | FNA |
| Tagline | আপনার টাকার নিরাপদ ঘর | A safe nest for your money |
| Self-introduction (exact) | আমি ফিননেস্ট সহকারী বলছি। | This is FinNest Assistant. |

The old names **Bhorosha / ভরসা** and **Apa / আপা** never appear in new copy, on screen, in audio or in a
deck. They survive only in code identifiers (`com.bhorosha.app`, the Dart package, `Apa*` classes), which
users never see. Bangla case endings take a hyphen after the abbreviation (এফএনএ-কে, এফএনএ-র) and none
after the full name (ফিননেস্টের, ফিননেস্ট সহকারীকে).

### The mark

A green woven bowl (the nest) held by a teal hand, a shield outline rising behind it, three gold coins
inside. It means "your money, held safely". File: `assets/finnest-mark.png` (square, transparent, about 4 %
built-in padding). It is derived from the FinNest logo by `apps/mobile/tool/make_brand_assets.py`;
never hand-edit or redraw it.

- **Where:** the login / sign-in screen above the wordmark, the launcher icon, the splash, the console's
  sign-in and header, the deck title slide. It is not decoration for other screens.
- **Clear space:** at least 25 % of the mark's width on every side, free of text and edges.
- **Minimum size:** 32 px (dp) on screen; 48 px when it stands alone (launcher legacy icon); the app's
  login uses 88 dp. Below 32 px use the wordmark alone.
- **Background:** the surface colour, or the icon off-white `#F6F8EA` (launcher, splash). In dark mode the
  mark sits on the dark surface unchanged; it carries its own contrast.
- **Adaptive icon:** mark at 56 dp on the 108 dp canvas (inside the 66 dp safe circle).

### The wordmark

"FinNest" set as **text**, never an image, in two tones: **Fin** in brand leaf, **Nest** in brand navy.
It reads "FinNest" in both languages (the wordmark is not translated); screen readers read the localised
app name (ফিননেস্ট / FinNest), not the two halves.

| | Light | Dark |
|---|---|---|
| Brand leaf ("Fin") | `#729C4A` (3.06:1 on surface) | `#9CCB6E` (9.71:1) |
| Brand navy ("Nest") | `#1E3459` (11.89:1) | `#B7C8E8` (10.81:1) |

The light leaf is only 3.06:1, so the wordmark is used at display size only (34 sp / 2.125 rem bold and up,
which counts as large text). Lockup: the mark above the wordmark, left-aligned. If the mark fails to load,
the wordmark stands alone; the brand never disappears.

The assistant's avatar is the square **"FNA" monogram** tile in `primary` with `onPrimary` letters. No
photographs of people anywhere; person avatars are initials on `primaryContainer`.

### Don'ts

- Don't recolour, stretch, rotate, outline, shadow or animate the mark; don't put it on a photo or a busy
  fill; don't crop it to the coins or the hand.
- Don't render the wordmark in one colour, in another face, in ALL CAPS, or as "Fin Nest" / "Finnest".
- Don't pair the brand with the flag colours (bottle green `#006A4E` with red `#F42A41`), party symbols
  (boat, sheaf of paddy, scales), religious motifs, or saffron.
- Don't name or show a real bank, telco or wallet brand as ours.

---

## 2. Colour

Colour carries meaning, not decoration. Brand colours say "FinNest, trust, act here"; status colours say
"what happened to your money". Nothing else gets a colour.

### Brand

The default theme is **FinNest teal** (ফিননেস্ট টিল). It is the brand: the logo's teal hand and green bowl
sit closest to it, and the deck, the video and the console should use it.

| Token | Light | Dark | Use |
|---|---|---|---|
| `primary` / `onPrimary` | `#0F6E67` / `#FFFFFF` (6.09:1) | `#7FD1C8` / `#00302B` (8.13:1) | The one primary action, links, focus, selection |
| `primaryContainer` / `onPrimaryContainer` | `#D3ECE8` / `#06302C` (11.54:1) | `#0E4A45` / `#C6EFEA` (8.13:1) | Selected chips and tiles, person avatars |
| `accent` | `#7B4B94` (6.14:1) | `#D2B3E3` (9.81:1) | Assistant ring, "new" badge, selected tick. Icons and badges; text only on `surface` |
| `surface` / `surfaceVariant` | `#FBFAF6` / `#F1EFE8` | `#121615` / `#1C2120` | Screen / cards, skeletons |
| `onSurface` / `mutedText` | `#1B1B1B` (16.49:1) / `#5B5F66` (6.14:1) | `#F2F1EC` (16.13:1) / `#B4B8BD` (9.15:1) | Text / captions |
| `outline` / `outlineVariant` | `#878C88` (3.28:1) / `#D9D6CC` | `#6F7774` (3.97:1) / `#3A403E` | Borders that must read / dividers |
| `brandLeaf`, `brandNavy` | see the wordmark | | Wordmark only |
| icon background | `#F6F8EA` | | Launcher and splash only |

Ratios are WCAG 2.x, against `surface` unless a pair is given.

**User themes.** The app's Settings also offers four more presets: Padma green (পদ্মা সবুজ), Jamdani indigo
(জামদানি নীল), Shapla plum (শাপলা বেগুনি) and Monsoon slate (বর্ষা স্লেট). They are user preferences, not
brand colours: they swap only the brand tokens above (`color.preset.*` in `tokens.json`,
`data-preset` on the web), every pair passes AA, and status colours never change with them. Use them only
where a user chose them. Marketing, the deck and docs always use FinNest teal; the operator console (FinNest
Admin) offers the same five in its Settings as a per-browser preference, teal by default, as the app does. A
picker shows each choice with its swatch, `var(--fn-preset-<name>)` (that preset's primary in the current
mode), so every option reads correctly whichever preset is active. There is no
amber or red preset on purpose: an amber primary would make every button look like a hold.

### Status

Identical in every preset; they differ only by mode. Each status has five roles: **text** (text and icons
on `surface` / `surfaceVariant`), **fill** + **onFill** (buttons, stripes, overlay strip), **container** +
**onContainer** (soft cards and tags).

| Status | Means | Text light / dark | Fill / onFill | Container / onContainer light | dark |
|---|---|---|---|---|---|
| danger | **Block**, danger, errors, wrong PIN | `#B3261E` (6.26) / `#F2B8B5` (10.68) | `#B3261E` / `#FFFFFF` (6.54) | `#FBE4E2` / `#410E0B` (13.38) | `#4A1714` / `#FFDAD6` (11.41) |
| warning | **Hold**, wait, delay, step-up, pending, simulated | `#8A5A00` (5.67) / `#FFC95C` (11.95) | `#D98E04` / `#1B1B1B` (6.42) | `#FFF1D6` / `#2E1F00` (14.33) | `#3D2C05` / `#FFE7B0` (11.09) |
| success | **Safe**, done, credit | `#1E7B3A` (5.09) / `#7DD99A` (10.65) | `#1E7B3A` / `#FFFFFF` (5.32) | `#DFF3E4` / `#0A2E16` (12.77) | `#12361E` / `#C3F0CF` (10.61) |
| info | **Neutral facts**, demo notes, requested | `#1F5FA8` (6.17) / `#9CC3F2` (9.99) | (uses text colour) | `#E1ECF8` / `#0B2545` (12.86) | `#14304F` / `#D6E6FA` (10.58) |
| neutral | Cancelled, released | `mutedText` | `outline` | `surfaceVariant` / `mutedText` | |

Status text on its own container: danger 5.38 / 8.64, warning 5.31 / 8.82, success 4.58 / 7.80,
info 5.38 / 7.35 (light / dark).

Rules:

1. **Red is block only.** One red in the system. A hold is amber, never red; red is also the colour of
   Pohela Boishakh, so a red-heavy screen reads "festival" before "danger". Keep it rare so it means one thing.
2. **The amber fill `#D98E04` is never text** (2.57:1 on the light surface). Amber text is `warning` `#8A5A00`.
3. **Status is never colour alone:** every status has an icon and a word ("আটকে আছে / On hold").
4. **Status colours are not brand colours.** No green "Get started" button, no red decoration, no
   info-blue headers. Green means safe; primary teal means "act here".
5. Dark mode is real (the demo phone runs dark): containers are dark tints with light text, never light
   pastels on a black screen. Check both modes.

---

## 3. Typography

### Faces

| Role | Bangla (default) | English |
|---|---|---|
| Text | **SolaimanLipi**, 400 and 700 only; Latin words inside Bangla fall back to Roboto | **Roboto** (system on Android); web: Roboto, then system UI; SolaimanLipi as fallback for Bangla names and server text |
| Big amounts | **Baloo Da 2**, variable, weight 800, Bangla and Latin digits in one file | same |

- SolaimanLipi has only 400 and 700. Never ask for 500 or 600 in Bangla (the engine fakes a bold).
  English may use 500 (titles, labels, buttons).
- **The display rule:** Baloo Da 2 is for amounts (and other big digit runs) only, never for words, titles
  or the wordmark. It makes the amount the one heavy object on the screen.
- No ALL CAPS, no italics (SolaimanLipi has none; slanted Bangla is unreadable).
- Bangla letter spacing is always 0 (tracking breaks matras and conjuncts).

### Scale

Sizes in sp (Android) = CSS px at 100 % zoom (the CSS uses rem, so browser text size is respected).
Weight / line height / letter spacing. Full set in `tokens.json` `typography.bn` and `typography.en`.

| Role | Bangla | English | Used for |
|---|---|---|---|
| displaySmall | 34 / 700 / 1.25 | 32 / 500 / 1.2 / -0.25 | Wordmark line, codes |
| headlineMedium | 26 / 700 / 1.3 | 24 / 500 / 1.25 | Result and overlay titles |
| headlineSmall | 22 / 700 / 1.35 | 22 / 500 / 1.27 | Sheet and empty-state titles |
| titleLarge | 22 / 700 / 1.35 | 20 / 500 / 1.3 | App bar titles |
| titleMedium | 20 / 700 / 1.35 | 18 / 500 / 1.33 / 0.1 | Section headers, card titles |
| titleSmall | 18 / 700 / 1.4 | 17 / 500 / 1.35 / 0.1 | Row titles, names |
| bodyLarge | 20 / 400 / 1.5 | 18 / 400 / 1.45 / 0.15 | Long reading text, reasons |
| **bodyMedium** | **18 / 400 / 1.5** | **17 / 400 / 1.45 / 0.15** | **Default body** |
| bodySmall (muted) | 16 / 400 / 1.45 | 16 / 400 / 1.4 / 0.2 | Captions, subtitles |
| labelLarge | 20 / 700 / 1.2 | 18 / 500 / 1.2 / 0.1 | Buttons |
| labelMedium | 18 / 700 / 1.2 | 16 / 500 / 1.2 / 0.2 | Chips, tags, tile labels |
| labelSmall (muted) | 16 / 700 / 1.2 | 16 / 500 / 1.2 / 0.3 | Small badges, status tags |
| script | 22 / 700 / 1.5 | (Bangla only) | The assistant's spoken line |
| Display amount | 44 / 800 / 0.95 | 44 / 800 / 0.9 / -1 % | Amounts on confirm and result |
| Display hero | 52 / 800 / 0.95 | 52 / 800 / 0.9 / -1 % | Home balance |

Rules: **16 sp is the floor** for every role in both languages. Line height under 1.4 only for digits and
single short lines (amounts, labels, numpad). Reading text stays in full-width columns.

### Numbers and money

- Digits follow the language: Bangla digits in Bangla, Latin digits in English. **Lakh grouping always**:
  `৳ ৫,০০,০০০` / `৳ 5,00,000`. On the web: `Intl.NumberFormat('bn-BD')` and `Intl.NumberFormat('en-IN')`.
- Format: `৳` + space + amount. On a big amount the `৳` is 60 % of the digit size, muted, 6 px gap.
- Signs only in lists: debit `− ৳ ৩,২০৯` (U+2212 minus), credit `+ ৳ ১,৪৫০`. Never on confirmation screens.
- Spoken / screen-reader form: "৫,০০০ টাকা" / "5,000 taka", never the symbol.
- Bangla digits differ in width: amounts that change render each digit in a fixed-width slot (Latin uses
  tabular figures).

---

## 4. Space, size, shape, elevation

8 px grid with a 4 px half-step (`space`): `xxs` 2, `xs` 4, `s` 8 (inside rows, between chips and stacked
buttons), `m` 16 (screen gutter, card padding, block gap), `l` 24 (between sections), `xl` 32 (above a
hero), `xxl` 48 (empty-state top).

Sizes (`size`): touch target **56**, PIN keys 72, amount keys 64 (56 compact), list row 72 (64 compact),
app bar 64 (56 compact), bottom-bar button 56, avatar 48 / 40, status stripe 4. Compact layout below 700 px
screen height.

- **Radius: 0.** Square corners everywhere: buttons, cards, inputs, chips, sheets, dialogs, tags, the
  assistant tile. Never add a radius.
- **Elevation: 0.** No shadows. Separation comes from fills (`surfaceVariant`, status containers) and 1 px
  `outlineVariant` dividers.
- Borders: 1 px hairline (dividers, inputs), 2 px focus / outlined button / selected tile, 4 px leading
  stripe on status cards.
- Layout (Wise-inspired restraint): one column, generous whitespace, one primary action per screen, full
  width, at the bottom in the thumb zone. The balance sits on the surface with no card. No gradients, no
  glass, no illustrations competing with the amount.

---

## 5. Motion

Calm, quick and honest. Motion confirms what happened; it never celebrates something the user should
worry about.

| Token | ms | Easing | Use |
|---|---|---|---|
| press / release | 90 / 150 | ease-out / ease-out-cubic | Press-in and out (0.97 scale + shade) |
| fast | 150 | ease-out-cubic | Cross-fades, chip selection, tag colour changes |
| normal | 240 | enter `cubic-bezier(0.2, 0, 0, 1)` | Step transitions, panels, list inserts, entrances |
| exit | 200 | `cubic-bezier(0.3, 0, 0.8, 0.15)` | Anything leaving |
| overlay | 280 | enter | Sheets and overlays: slide up 32 px + fade |
| slow | 360 | ease-in-out-cubic | Theme change |
| emphasis | 400 | `cubic-bezier(0.34, 1.26, 0.64, 1)` (about 4 % overshoot) | Friendly moments only |
| checkDraw | 480 | | Success check draw |
| counter | 600 | ease-out-cubic | Amount roll / balance count-up |
| stagger | 40 | | Between list items on first paint, max 5 |
| pulse, shimmer / breathe | 1200 / 1600 loop | ease-in-out / linear | Speaking ring, skeleton, "checking" dot |
| crossfade | 120 | | The reduce-motion substitute for value changes |

Full list in `tokens.json` `motion`. Rules:

1. **Never celebrate a hold or a block.** No check mark, no overshoot (use `firm` = enter), no confetti, no
   pulse once a block has settled. Success motion is for success only.
2. Amounts on confirmation screens do not move after first paint. Overlay action buttons are tappable and
   still from the first frame.
3. Reduced motion (`prefers-reduced-motion` / Android "remove animations"): every duration is zero, loops
   show a still frame; only the 120 ms cross-fade remains.
4. Loops are bounded or tied to a state (checking, speaking).
5. Feedback: pressed state in the same frame, a result or progress state within 100 ms. Skeletons, never a
   spinner, for content with a known shape.

---

## 6. Iconography

- Material icons, outlined variant by default (the app uses Flutter's built-in `Icons.*_outlined` set; on
  the web use Material Symbols Outlined, weight 400, which has the same glyphs). 24 px in rows and
  buttons, 20 px minimum. Filled variants only for a selected state.
- **Every icon has a text label.** No icon-only buttons, including close and settings.
- Icons take the colour of the text beside them; status icons take the status text colour.
- Leading row tiles: 48 px square. People: initial on `primaryContainer`. Non-people (agent, biller,
  salary): icon on `surfaceVariant`. Credits: `successContainer`.
- No religious, party or flag imagery; no photographs of people.

---

## 7. Voice and tone

The assistant is a calm, plain-spoken guide, not a person: short sentences, one next step, no blame.

**Bangla (default).** Simple colloquial standard Bangla (চলিত ভাষা) that a first-time reader can read aloud.
Polite আপনি form for the user. The assistant uses non-honorific verbs about itself ("এফএনএ দেখছে",
"ভাবছে"). Plain verbs: "টাকা পাঠান", "বিল দিন", not "ফান্ড ট্রান্সফার" or "পেমেন্ট প্রসেস". Explain a term the
first time: "ওটিপি (এসএমএসে আসা গোপন কোড)". Greet with "স্বাগতম, {name}".

**English (the parallel, not the default).** Plain, warm, sentence case, contractions are fine. Same
meaning as the Bangla, not a word-for-word translation. "Send money", "Pay a bill", "This is FinNest
Assistant."

**Always**

- Every string exists in both languages; the user switches with one control (বাংলা | English).
- Errors say what to do next ("আবার চেষ্টা করুন / Try again"); never a dead end; money never moves on a
  silent failure.
- Holds explain the reason in the server's own words; the client never invents why money was stopped.
- Demo and simulated states say so on screen ("ডেমো মোড", "সিমুলেটেড").
- Standing trust line: "ফিননেস্ট কখনো আপনার পিন বা ওটিপি চায় না / FinNest never asks for your PIN or OTP."

**Never**

- Bhorosha, ভরসা, Apa, আপা; "এফএনএ বলছি" or "আমি আপা" as the self-introduction.
- Religion-specific greetings (নমস্কার, আসসালামু আলাইকুম, …).
- Code names on screen: request ids, enum or wire values, package names, status codes, model names. A
  reference is a short labelled suffix in muted text.
- Real bank, telco or wallet names as ours; jargon; ALL CAPS; exclamation marks around money.

---

## 8. Accessibility floors

| Floor | Value |
|---|---|
| Text size | 16 sp / px minimum, body 18 (Bangla) / 17 (English); respect system text size up to 1.4x |
| Touch target | 56 dp / px minimum (Material's 48 is not enough for these users) |
| Contrast | Text 4.5:1, large text and meaningful borders 3:1; every token pair above passes |
| Colour | Never the only signal; icon + word for every status |
| Motion | Honour reduced motion; no flashing |
| Screen readers | Every control labelled in the active language; amounts read as words ("৫,০০০ টাকা"); the wordmark reads as one word |
| Language | `lang="bn"` / `lang="en"` set on the page or widget so fonts and voices switch |

---

## 9. Platform notes

**Flutter (Android app).** The values live in `apps/mobile/lib/app/theme/` (`palette.dart`,
`tokens.dart`, `typography.dart`, `motion.dart`, `theme.dart`); see `flutter.md` for the map and
`apps/mobile/lib/app/widgets/` for the shared widgets. Use `context.palette`, `context.textRoles`, `BhMotion.of(context)`, `BhSpace`, `BhSize`; never a raw
colour, size or duration in a feature file.

**Web (console, landing pages, demos).** Link `web/finnest.css` (copy `web/fonts/` beside it), set
`<html lang="bn" class="fn">` (or `lang="en"`), and use the variables (`var(--fn-primary)`,
`var(--fn-space-m)`, `var(--fn-duration-normal)`) or the `.fn-*` classes (`.fn-button`, `.fn-tag[data-status]`,
`.fn-card`, `.fn-amount`, `.fn-wordmark`, `.fn-body-medium`, …). Dark mode follows the system; force it with
`data-theme="dark"|"light"`. In light mode the root declares `color-scheme: only light`, which tells browsers
with a forced dark mode (Chrome's Auto Dark Mode for Web Contents, Samsung Internet) not to repaint the page:
without `only`, a reader who chose light got an algorithmically darkened page. Tailwind users add `web/finnest.tailwind.js` as a preset (classes such as
`bg-fn-primary`, `text-fn-body-medium`, `p-fn-m`, `min-h-fn-touch`). Tailwind v4 users can skip the preset and
map the variables in `@theme inline`.

Desktop operator tools (the console) may be denser than the phone app: 16 px text floor still holds, but
targets may drop to 40 px for mouse-only controls, and tables may use `bodySmall`. Everything else (colour
meaning, square corners, no shadows, faces, voice, no code names in customer-facing copy) is the same.
Operator-facing ids (case ids, rule ids) are fine in the console; it is a tool for analysts, not customers.
