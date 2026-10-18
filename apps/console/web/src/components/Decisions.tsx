/**
 * The funnel, the reason codes and what they fire alongside.
 *
 * The note about the seven codes that cannot fire is not decoration. Without it the chart reads as
 * "the other seven rules never catch anything", when the truth is that the seed world carries no
 * signal that could make them fire.
 */

import type { Replay } from '../lib/types'
import { n, ratio, tone } from '../lib/format'
import { BarRow, Panel, Explainer } from './primitives'
import { useT } from '../lib/i18n'
import { Icon } from './Wordmark'

const ORDER = ['allow', 'step_up', 'delay', 'hold', 'block'] as const

export function Decisions({ replay }: { replay: Replay }) {
  const { t, pick } = useT()
  const max = Math.max(...Object.values(replay.mix), 1)
  const codeMax = Math.max(...Object.values(replay.codes), 1)
  const cooccurrence = Object.entries(replay.cooccurrence)

  return (
    <div className="grid g-2">
      <Panel title={t('decisions.title')} question={t('decisions.q')} badge={replay.badge}>
        <div className="grid" style={{ gap: 7 }}>
          {ORDER.map((key) => (
            <BarRow
              key={key}
              name={`${t(`decisions.${key}`)}  ${key}`}
              count={replay.mix[key] ?? 0}
              max={max}
              toneKey={tone(key)}
              suffix={
                <span className="dim">
                  {ratio(replay.mix[key] ?? 0, replay.denominator)}
                </span>
              }
            />
          ))}
        </div>
        <p className="panel-note">{t('decisions.noblock')}</p>
      </Panel>

      <Panel title={t('codes.title')} question={t('codes.q')} badge="RULE" info="codes">
        <div className="grid" style={{ gap: 7 }}>
          {Object.entries(replay.codes).map(([code, count]) => (
            <BarRow key={code} name={code} count={count} max={codeMax} toneKey="high" />
          ))}
        </div>
        {cooccurrence.length > 0 && (
          <Explainer>
            {t('codes.together')}{' '}
            {cooccurrence.map(([pair, count]) => (
              <code key={pair}>
                {pair} — {n(count)}×
              </code>
            ))}
          </Explainer>
        )}
        <div className="note">
          <Icon name="info" />
          <div>
          <b>
            {n(replay.codes_that_cannot_fire.length)} {t('codes.cannot')}
          </b>{' '}
          {pick(replay, 'codes_that_cannot_fire_reason')}.
          <div className="mono dim">{replay.codes_that_cannot_fire.join(' · ')}</div>
          </div>
        </div>
      </Panel>
    </div>
  )
}
