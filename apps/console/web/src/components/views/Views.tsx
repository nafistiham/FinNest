/**
 * The views that are mostly composition: each one picks the panels an operator needs for one
 * question and leaves the rest out. The panels themselves are unchanged - this is about what sits
 * on a screen together, not about new charts.
 */

import type { Overview } from '../../lib/types'
import { digits, fx, n, pct, taka, tone } from '../../lib/format'
import { CatchVsFriction } from '../CatchVsFriction'
import { Decisions } from '../Decisions'
import { GateLadder } from '../GateLadder'
import { Ledger } from '../Ledger'
import { ModelHealth } from '../ModelHealth'
import { PilotTargets } from '../PilotTargets'
import { PolicyChecks } from '../PolicyChecks'
import { Panel, Tile, Explainer } from '../primitives'
import { DailyChart, ShareBar, TypologyBars } from '../charts'
import { useT } from '../../lib/i18n'
import { Icon } from '../Wordmark'

export function OverviewView({
  overview,
  onOpenAccount,
  onPickTypology,
}: {
  overview: Overview
  onOpenAccount: (id: string) => void
  onPickTypology: (typology: string) => void
}) {
  const { t, pick, lang } = useT()
  const { replay, weakest_link } = overview
  const mule = overview.models.find((model) => model.id === 'mule-lgbm')
  const failing = overview.policy.filter((check) => !check.ok)
  return (
    <>
      <div className="grid g-4">
        <Tile
          label={t('kpi.protected')}
          info="protected"
          value={taka(replay.value.protected_bdt, lang)}
          sub={`${n(replay.confusion.catch)} ${t('kpi.protected.sub')}`}
          badge="RULE"
        />
        <Tile
          label={t('kpi.friction')}
          info="friction"
          value={taka(replay.value.friction_bdt, lang)}
          sub={`${n(replay.confusion.false_positive)} ${t('kpi.friction.sub')}`}
          badge="RULE"
        />
        <Tile
          label={t('kpi.catch')}
          info="catch"
          value={pct(replay.rates.catch_rate)}
          sub={`${n(replay.confusion.catch)} ${t('kpi.of')} ${n(replay.rates.catch_rate_denominator)}`}
          badge="RULE"
        />
        <Tile
          label={t('kpi.fpr')}
          info="fpr"
          value={pct(replay.rates.false_positive_rate, 2)}
          sub={`${n(replay.confusion.false_positive)} ${t('kpi.of')} ${n(replay.rates.false_positive_rate_denominator)}`}
          badge="RULE"
        />
      </div>

      {failing.length > 0 && (
        <div className="note bad">
          <Icon name="error" />
          <div>
            <b>
              {n(failing.length)} {t(failing.length === 1 ? 'policy.failing.one' : 'policy.failing.many')}
            </b>{' '}
            {failing.map((check) => pick(check, 'statement')).join(' ')}
          </div>
        </div>
      )}

      <GateLadder gates={overview.gates} weakest={pick(weakest_link, 'sentence')} />
      <Panel title={t('share.title')} question={t('decisions.q')} badge={replay.badge} info="denominator">
        <ShareBar mix={replay.mix} total={replay.denominator} />
      </Panel>

      <PilotTargets targets={overview.targets} />
      <CatchVsFriction replay={replay} />

      {mule?.per_segment && (
        <Panel title={t('typology.title')} question={t('typology.q')} badge="MODEL" info="typology">
          <TypologyBars segments={mule.per_segment} label={t('typology.label')} onPick={onPickTypology} />
        </Panel>
      )}

      <Panel title={t('volume.title')} question={`${n(overview.window.days)} ${t('volume.q')}`} badge={replay.badge}>
        <DailyChart days={replay.daily} />
      </Panel>

      <Panel title={t('watch.title')} question={t('watch.q')}>
        <div className="grid g-3">
          {overview.mule_board.slice(0, 6).map((row) => (
            <Tile
              key={row.acct}
              label={row.acct}
              value={fx(row.probability, 3)}
              sub={`${row.role ?? t('accounts.unlabelled')} · ${row.typology ?? '—'}`}
              badge="MODEL"
              onClick={() => onOpenAccount(row.acct)}
            />
          ))}
        </div>
      </Panel>
    </>
  )
}

export function GatesView({ overview }: { overview: Overview }) {
  const { t, pick } = useT()
  return (
    <>
      <GateLadder gates={overview.gates} weakest={pick(overview.weakest_link, 'sentence')} />
      <Panel title={t('gates.full')} question={t('gates.full.q')}>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>{t('view.gates')}</th>
                <th>{t('gates.sees')}</th>
                <th>{t('gates.owner')}</th>
                <th>{t('gates.status')}</th>
                <th className="num">{t('gates.volume')}</th>
                <th className="num">{t('gates.caught')}</th>
              </tr>
            </thead>
            <tbody>
              {overview.gates.map((gate) => (
                <tr key={gate.id}>
                  <td>
                    <b>
                      {gate.id} · {pick(gate, 'title')}
                    </b>
                    <div className="dim">
                      {pick(gate, 'note')}
                    </div>
                  </td>
                  <td className="dim">{gate.sees}</td>
                  <td className="mono dim">{gate.owner_ticket ?? '—'}</td>
                  <td>
                    <span className={`chip t-${tone(gate.badge)}`}>
                      {gate.status}
                    </span>
                  </td>
                  <td className="num">{gate.volume === null ? '—' : n(gate.volume)}</td>
                  <td className="num">{gate.caught === null ? '—' : n(gate.caught)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <Explainer>
          <code>defence-in-depth plan</code> · {t('gates.dash')}
        </Explainer>
      </Panel>
      <PolicyChecks policy={overview.policy} />
    </>
  )
}

export function RiskView({ overview }: { overview: Overview }) {
  return (
    <>
      <Ledger replay={overview.replay} />
      <Decisions replay={overview.replay} />
      <CatchVsFriction replay={overview.replay} />
    </>
  )
}

export function ModelsView({
  overview,
  onPickTypology,
}: {
  overview: Overview
  onPickTypology: (typology: string) => void
}) {
  const { t } = useT()
  const mule = overview.models.find((model) => model.id === 'mule-lgbm')
  return (
    <>
      {mule?.per_segment && (
        <Panel title={t('typology.title')} question={t('typology.q')} badge="MODEL" info="typology">
          <TypologyBars segments={mule.per_segment} label={t('typology.label')} onPick={onPickTypology} />
        </Panel>
      )}
      <ModelHealth models={overview.models} />
      <Panel title={t('models.thresholds')} question={t('models.thresholds.q')}>
        <div className="grid g-4">
          {Object.entries(overview.source.thresholds).map(([name, value]) => (
            <Tile key={name} label={name} value={typeof value === 'number' ? digits(String(value)) : String(value)} badge="RULE" small />
          ))}
        </div>
        <Explainer>{t('models.thresholds.note', { service: overview.source.service })}</Explainer>
      </Panel>
    </>
  )
}
