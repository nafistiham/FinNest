/**
 * The ⓘ that explains a figure in plain language.
 *
 * This console is full of terms an operations manager has every right not to know - SHAP, ring
 * recall, denominator, p(mule), provenance. Hiding them would make the page friendlier and less
 * true. Explaining them in place is the other way out, and it costs one small button.
 *
 * Click, not hover: a tooltip that needs a mouse is a tooltip half the team cannot read.
 */

import { useEffect, useId, useRef, useState } from 'react'
import { useT } from '../lib/i18n'
import { Icon } from './Wordmark'

export function Info({ k }: { k: string }) {
  const { t } = useT()
  const [open, setOpen] = useState(false)
  const id = useId()
  const ref = useRef<HTMLSpanElement>(null)

  useEffect(() => {
    if (!open) return
    const onAway = (event: MouseEvent) => {
      if (!ref.current?.contains(event.target as Node)) setOpen(false)
    }
    const onKey = (event: KeyboardEvent) => event.key === 'Escape' && setOpen(false)
    document.addEventListener('mousedown', onAway)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onAway)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  const body = t(`info.${k}`)
  if (body === `info.${k}`) return null // no explanation written yet: show nothing rather than a dead button

  return (
    <span className="info" ref={ref}>
      <button
        type="button"
        className="info-btn"
        aria-expanded={open}
        aria-label={t('info.button')}
        title={t('info.button')}
        aria-describedby={open ? id : undefined}
        onClick={(event) => {
          event.stopPropagation()
          setOpen(!open)
        }}
      >
        <Icon name="info" filled={open} />
      </button>
      {open && (
        <span className="info-pop" id={id} role="tooltip">
          {body}
        </span>
      )}
    </span>
  )
}
