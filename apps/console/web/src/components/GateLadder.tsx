/**
 * The defence as a ladder, G0 to G7.
 *
 * The vocabulary is the team's defence-in-depth plan, not one this console invented, so an argument
 * about the dashboard is an argument about the plan. A gate with no measurement shows a dash: a
 * zero would read as "this gate caught nothing", which is a different and false claim.
 */

import { useState } from 'react'
import type { Gate } from '../lib/types'
import { n, tone } from '../lib/format'
import { Badge, Panel } from './primitives'
import { Info } from './Info'
import { useT } from '../lib/i18n'
import { Icon } from './Wordmark'

export function GateLadder({ gates, weakest }: { gates: Gate[]; weakest: string }) {
  const { t, pick } = useT()
  const [selected, setSelected] = useState<string>('G4')
  const current = gates.find((gate) => gate.id === selected) ?? gates[0]

  return (
    <Panel title={t('gates.title')} question={t('gates.q')} info="gates">
      <div className="ladder">
        {gates.map((gate) => (
          <button
            type="button"
            key={gate.id}
            className={`gate${gate.id === selected ? ' selected' : ''}`}
            aria-pressed={gate.id === selected}
            style={{ ['--tone' as string]: `var(--${tone(gate.badge)}-fill)` }}
            onClick={() => setSelected(gate.id)}
          >
            <div className="id">{gate.id}</div>
            <div className="title">{pick(gate, 'title').split(':')[0]}</div>
            <div className="metric">
              <span>{gate.volume_label ? pick(gate, 'volume_label') : t('gates.volume')}</span>
              <b>{gate.volume === null ? '—' : n(gate.volume)}</b>
            </div>
            <div className="metric">
              <span>{gate.caught_label ? pick(gate, 'caught_label') : t('gates.caught')}</span>
              <b>{gate.caught === null ? '—' : n(gate.caught)}</b>
            </div>
            <Badge kind={gate.badge} />
          </button>
        ))}
      </div>

      {current && (
        <div className="tile gate-detail">
          <div className="row">
            <b>
              {current.id} · {pick(current, 'title')}
            </b>
            <Badge kind={current.badge} />
            <span className="chip t-muted">{t('gates.sees')}: {current.sees}</span>
            {current.owner_ticket && <span className="chip t-info">{current.owner_ticket}</span>}
            <span className="chip t-muted">{current.status}</span>
          </div>
          <div>{pick(current, 'note')}</div>
        </div>
      )}

      <div className="note bad">
        <Icon name="error" />
        <div>
          <b>{t('gates.weakest')}</b> {weakest} <Info k="weakest" />
        </div>
      </div>
    </Panel>
  )
}
