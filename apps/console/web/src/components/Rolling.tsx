/**
 * A figure whose digits roll into place: the console's version of the app's RollingAmount
 * (apps/mobile/lib/app/widgets/animated/rolling_amount.dart), on the same motion tokens.
 *
 * - Every digit sits in its own slot. The slot holds a strip of all ten digits of the active
 *   script, so its width is the widest digit's and nothing jitters while a digit moves; grouping
 *   commas, the decimal point and the units stay still.
 * - First paint: each digit of the final figure rises into its slot over `--fn-duration-counter`
 *   (600 ms, ease-out-cubic). The leading digit settles first (at 65 % of the run) and the last one
 *   at 100 %, so the eye reads the magnitude before the detail. No frame shows a different number:
 *   the console's rule is that a figure on screen is the figure (see lib/ui.ts).
 * - A later change (a rebuild) rolls only the digits that changed, old to new. A slot that is new
 *   (999 -> 1,000) rises in like a first paint.
 * - `৳` and unit words (lakh, লাখ) are text, not display digits: 60 % size, muted, per the
 *   design system's amount rule. The display face is for digits only.
 * - Screen readers get the whole value once (`aria-label`); the slots are hidden from them.
 * - Reduced motion: finnest.css zeroes the counter duration, so digits are simply there; a change
 *   cross-fades over `--fn-duration-crossfade`, the one motion the design system keeps.
 */

import { useEffect, useRef, useState, type CSSProperties } from 'react'

const LATIN = '0123456789'
const BANGLA = '০১২৩৪৫৬৭৮৯'

const digitOf = (ch: string): { value: number; script: string } | null => {
  let index = LATIN.indexOf(ch)
  if (index >= 0) return { value: index, script: LATIN }
  index = BANGLA.indexOf(ch)
  if (index >= 0) return { value: index, script: BANGLA }
  return null
}

/** A run of non-digits is a unit (taka sign, a word) or punctuation (, . % and spaces). Runs are
    never split into characters: a Bangla word is letters plus vowel signs and only shapes whole. */
const isUnit = (run: string) => run.includes('৳') || /\p{L}/u.test(run)

type Piece = { kind: 'digit'; ch: string } | { kind: 'run'; text: string }

const split = (text: string): Piece[] => {
  const pieces: Piece[] = []
  for (const ch of text) {
    if (digitOf(ch)) pieces.push({ kind: 'digit', ch })
    else {
      const last = pieces[pieces.length - 1]
      if (last?.kind === 'run') last.text += ch
      else pieces.push({ kind: 'run', text: ch })
    }
  }
  return pieces
}

export function Rolling({ text }: { text: string }) {
  const pieces = split(text)
  const digitCount = pieces.filter((piece) => piece.kind === 'digit').length
  const [changes, setChanges] = useState(0)
  const previous = useRef(text)

  useEffect(() => {
    if (previous.current !== text) {
      previous.current = text
      setChanges((count) => count + 1)
    }
  }, [text])

  let seen = 0
  return (
    <span className="roll" aria-label={text} role="img" data-changed={changes > 0 ? changes % 2 : undefined}>
      <span aria-hidden="true" className="roll-inner">
        {pieces.map((piece, index) => {
          /* Keyed from the right, so units stay units when a figure grows a digit. */
          const fromRight = pieces.length - index
          if (piece.kind === 'run') {
            return (
              <span key={`r${fromRight}`} className={isUnit(piece.text) ? 'roll-unit' : 'roll-punct'}>
                {piece.text}
              </span>
            )
          }
          const digit = digitOf(piece.ch)!
          const order = seen++
          /* Leading digit settles at 65 % of the counter run, the last one at 100 %. */
          const share = digitCount > 1 ? 0.65 + (0.35 * order) / (digitCount - 1) : 1
          const style = {
            '--roll-share': share,
            '--roll-y': `${-digit.value * 10}%`,
          } as CSSProperties
          return (
            <span key={`d${fromRight}`} className="roll-slot" style={style}>
              <span className="roll-strip">
                {[...digit.script].map((glyph) => (
                  <span key={glyph}>{glyph}</span>
                ))}
              </span>
            </span>
          )
        })}
      </span>
    </span>
  )
}
