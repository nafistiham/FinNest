/**
 * Transient messages. Errors stay twice as long, because they are the ones worth reading.
 *
 * Each one is a status card (design system: container fill, a 4 px leading stripe, an icon and a
 * word, never colour alone). It arrives like an overlay (`--fn-duration-overlay`, up 32 px and
 * fades in) and leaves on `--fn-duration-exit`. A good outcome may use the `emphasis` easing; an
 * error never does - the design system does not let motion celebrate or dramatise a problem.
 */

import { useToasts } from '../lib/ui'
import { useT } from '../lib/i18n'
import { Icon } from './Wordmark'

const LOOK = {
  error: { status: 'bad', icon: 'error' },
  good: { status: 'good', icon: 'check_circle' },
  info: { status: 'info', icon: 'info' },
} as const

export function Toasts() {
  const { t } = useT()
  const toasts = useToasts()
  return (
    <div className="toasts" role="status" aria-live="polite">
      {toasts.map((item) => {
        const look = LOOK[item.kind]
        return (
          <div key={item.id} className={`toast note ${look.status}${item.leaving ? ' leaving' : ''}`}>
            <Icon name={look.icon} />
            <div>
              <b>{t(`toast.${item.kind}`)}</b> {item.text}
            </div>
          </div>
        )
      })}
    </div>
  )
}
