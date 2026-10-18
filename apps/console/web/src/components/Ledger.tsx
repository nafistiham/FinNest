/**
 * Both sides of the ledger, emitted by one component.
 *
 * Value protected and friction imposed are the same size, side by side, neither emphasised. There
 * is no way to render one of them from this module, because a catch-rate chart without its cost is
 * a sales slide rather than an operating tool.
 */

import type { Replay } from '../lib/types'
import { n, taka } from '../lib/format'
import { Panel, Rate, Tile, Explainer } from './primitives'
import { useT } from '../lib/i18n'

export function Ledger({ replay }: { replay: Replay }) {
  const { t, lang } = useT()
  const { rates, confusion, value } = replay
  return (
    <Panel
      title={t('ledger.title')}
      question={t('ledger.q')}
      badge={replay.badge}
      info="denominator"
      right={
        <span className="chip t-muted">
          {t('ledger.denominator')}: {n(replay.denominator)} {replay.denominator_label}
        </span>
      }
    >
      <div className="grid g-4">
        <Tile
          label={t('kpi.protected')}
          info="protected"
          value={taka(value.protected_bdt, lang)}
          sub={`${n(confusion.catch)} ${t('kpi.protected.sub')}`}
          badge="RULE"
        />
        <Tile
          label={t('kpi.friction')}
          info="friction"
          value={taka(value.friction_bdt, lang)}
          sub={`${n(confusion.false_positive)} ${t('kpi.friction.sub')}`}
          badge="RULE"
        />
        <Rate
          label={t('kpi.catch')}
          info="catch"
          value={rates.catch_rate}
          numerator={confusion.catch ?? 0}
          denominator={rates.catch_rate_denominator}
          badge="RULE"
        />
        <Rate
          label={t('kpi.fpr')}
          info="fpr"
          value={rates.false_positive_rate}
          numerator={confusion.false_positive ?? 0}
          denominator={rates.false_positive_rate_denominator}
          badge="RULE"
        />
      </div>
      <Explainer>{t('ledger.note')}</Explainer>
    </Panel>
  )
}
