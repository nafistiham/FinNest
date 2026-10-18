/**
 * The FinNest name and mark, per the brand rules in `design-system` (README section 1).
 *
 * The wordmark is live text in two colours - "Fin" in brandLeaf, "Nest" in brandNavy - set with
 * the design system's own `.fn-wordmark` class: Roboto bold at displaySmall (34 px), never smaller,
 * never an image, never one colour, never translated. Screen readers hear the localised product
 * name, not the two halves.
 *
 * The mark is the nest bowl as drawn, used only where the brand allows it (sign-in and the console
 * header), at 32 px or more, with clear space around it, never recoloured, cropped, shadowed or
 * animated - which is why it is an <img> of the asset itself and why no motion rule in
 * styles.css ever selects `.brand-mark`. If it fails to load, it removes itself and the wordmark
 * stands alone; the brand never disappears.
 */

import { useT } from '../lib/i18n'

export function Wordmark() {
  const { t } = useT()
  return (
    <span className="fn-wordmark" role="img" aria-label={t('app.product')}>
      <span aria-hidden="true">Fin</span>
      <span aria-hidden="true">Nest</span>
    </span>
  )
}

export function Mark({ px = 40 }: { px?: number }) {
  return (
    <img
      className="brand-mark"
      src="./finnest-mark.png"
      alt=""
      width={px}
      height={px}
      onError={(event) => event.currentTarget.remove()}
    />
  )
}

/** A Material Symbols Outlined glyph. Decorative by contract: every icon sits beside a text label
    (README section 6), so the glyph itself is hidden from screen readers. */
export function Icon({ name, filled }: { name: string; filled?: boolean }) {
  return (
    <span className={`icon${filled ? ' icon--filled' : ''}`} aria-hidden="true">
      {name}
    </span>
  )
}
