/**
 * The left rail: every incident the radar opened, and the one selected.
 *
 * Default rank is surprise, then newest opening, then id. The money rank sorts by an eval-only field
 * and says so; the ledger rank waits for a truth-free producer and is disabled. The incident class is
 * an eval-only chip joined by incident_id, absent when there is no evaluation, never "benign" by
 * default. Observed is distinct senders at the firing snapshot, not the number of marks drawn.
 */

import { n } from '../../lib/format'
import { useT } from '../../lib/i18n'
import type { RadarCampaign, RadarIncident, RankBy } from '../../lib/campaigns'
import { fmtCount, pParts, stamp, surpriseExponent } from '../../lib/campaigns'
import { useCT } from '../../lib/campaignStrings'
import { Badge, Chip, Panel, Segmented } from '../primitives'

export type Scope = 'all' | 'campaign'

const Surprise = ({ value }: { value: number }) => (
  <span className="mono">
    1 in 10<sup>{surpriseExponent(value)}</sup>
  </span>
)

export function IncidentList({
  incidents,
  campaigns,
  classes,
  selected,
  onSelect,
  rankBy,
  onRankBy,
  scope,
  onScope,
  scopeCount,
  total,
  hasCampaign,
}: {
  incidents: RadarIncident[]
  campaigns: RadarCampaign[]
  classes: Map<string, string>
  selected: string | null
  onSelect: (incidentId: string) => void
  rankBy: RankBy
  onRankBy: (value: RankBy) => void
  scope: Scope
  onScope: (value: Scope) => void
  scopeCount: number
  total: number
  hasCampaign: boolean
}) {
  const ct = useCT()
  return (
    <Panel title={ct('cv.incidents')} badge="RULE">
      <label className="cv-rank">
        <span className="dim">{ct('cv.rankby')}</span>
        <select value={rankBy} onChange={(event) => onRankBy(event.target.value as RankBy)}>
          <option value="surprise">{ct('cv.rank.surprise')}</option>
          <option value="retained">{ct('cv.rank.retained')}</option>
          <option value="inside" disabled>
            {ct('cv.rank.inside')}
          </option>
        </select>
      </label>
      {rankBy === 'retained' && <p className="cv-sub">{ct('cv.rank.note')}</p>}
      {hasCampaign && (
        <div style={{ margin: '0 0 8px' }}>
          <Segmented
            value={scope}
            onChange={onScope}
            options={[
              { value: 'all', label: `${ct('cv.scope.all')} ${total}` },
              { value: 'campaign', label: `${ct('cv.scope.campaign')} ${scopeCount}` },
            ]}
          />
        </div>
      )}
      <div className="cv-list" role="listbox" aria-label={ct('cv.incidents')}>
        {incidents.map((incident) => {
          const holding = campaigns.filter((c) => c.incident_ids.includes(incident.incident_id))
          const klass = classes.get(incident.incident_id)
          return (
            <button
              key={incident.incident_id}
              type="button"
              role="option"
              aria-selected={selected === incident.incident_id}
              className={`cv-item${selected === incident.incident_id ? ' cv-on' : ''}`}
              onClick={() => onSelect(incident.incident_id)}
            >
              <span className="cv-cell">{incident.cell}</span>
              <span className="cv-meta">
                {incident.key} · {incident.window_min} min · {n(incident.observed)} / {fmtCount(incident.expected)} ·{' '}
                <Surprise value={incident.surprise} />
              </span>
              <span className="cv-chips">
                {holding.length === 0 && <span className="chip t-muted">{ct('cv.nocampaign')}</span>}
                {holding.map((c) => (
                  <span key={c.campaign_id} className={`chip ${c.superseded_by ? 't-muted' : 't-info'}`}>
                    {c.campaign_id}
                  </span>
                ))}
                {klass && (
                  <span className="chip t-muted" title={ct('cv.class.note')}>
                    {ct('cv.evalonly')} · {ct(`cv.class.${klass}`)}
                  </span>
                )}
              </span>
            </button>
          )
        })}
      </div>
    </Panel>
  )
}

export function IncidentSummary({
  incident,
  holding,
  chosen,
  onChoose,
  klass,
}: {
  incident: RadarIncident
  holding: RadarCampaign[]
  chosen: string | null
  onChoose: (campaignId: string) => void
  klass: string | undefined
}) {
  const ct = useCT()
  const { t } = useT()
  const [mantissa, exponent] = pParts(incident.p_value)
  const current = holding.filter((c) => c.superseded_by === null)

  return (
    <Panel title={ct('cv.incident')} badge="RULE">
      <dl className="cv-kv">
        <div className="cv-full">
          <dt>{ct('cv.incident')}</dt>
          <dd className="mono">{incident.incident_id}</dd>
        </div>
        <div className="cv-full">
          <dt>{ct('cv.cellkey')}</dt>
          <dd>
            <span className="mono">{incident.cell}</span> <span className="dim">{incident.key}</span>
          </dd>
        </div>
        <div>
          <dt>{ct('cv.opened')}</dt>
          <dd className="mono">{stamp(incident.opened_at)}</dd>
        </div>
        <div>
          <dt>{ct('cv.lastfiring')}</dt>
          <dd className="mono">{stamp(incident.last_fired_at)}</dd>
        </div>
        <div>
          <dt>{ct('cv.surprise')}</dt>
          <dd>
            <Surprise value={incident.surprise} />
          </dd>
        </div>
        <div>
          <dt>{ct('cv.reason')}</dt>
          <dd>
            <Chip kind="RULE">{incident.reason}</Chip>
          </dd>
        </div>
        <div>
          <dt>{ct('cv.obsexp')}</dt>
          <dd className="mono">
            {n(incident.observed)} / {fmtCount(incident.expected)}
          </dd>
        </div>
        <div>
          <dt>{ct('cv.window')}</dt>
          <dd className="mono">{incident.window_min} min</dd>
        </div>
        <div>
          <dt>{t('decisions.hold')}</dt>
          <dd className="mono">{n(incident.held)}</dd>
        </div>
        <div>
          <dt>{t('decisions.allow')}</dt>
          <dd className="mono">{n(incident.allowed)}</dd>
        </div>
        <div className="cv-full">
          <dt>{ct('cv.baseline')}</dt>
          <dd className="mono">
            {incident.baseline_source} · {ct('cv.payday')} {incident.payday_factor} · p = {mantissa} × 10<sup>{exponent}</sup> ·{' '}
            {incident.attempt_ids.length} {ct('cv.attached')}
          </dd>
        </div>
        <div className="cv-full">
          <dt>{ct('cv.campaign')}</dt>
          <dd className="cv-chips">
            {holding.length === 0 && <span className="dim">{ct('cv.nocampaign')}</span>}
            {holding.map((c) => (
              <button
                key={c.campaign_id}
                type="button"
                className={`sm${chosen === c.campaign_id ? ' on' : ''}`}
                aria-pressed={chosen === c.campaign_id}
                onClick={() => onChoose(c.campaign_id)}
              >
                {c.campaign_id}
                {c.superseded_by ? ` · ${ct('cv.earlier')}` : ''}
              </button>
            ))}
          </dd>
          {current.length > 1 && chosen === null && <p className="cv-sub">{ct('cv.choose')}</p>}
        </div>
        <div className="cv-full">
          <dt>{ct('cv.actionstaken')}</dt>
          <dd>
            <span className="chip t-warn">{ct('cv.notwired')}</span>
          </dd>
        </div>
        {klass && (
          <div className="cv-full">
            <dt>
              {ct('cv.evalonly')} <Badge kind="SYNTHETIC" />
            </dt>
            <dd>
              <span className="chip t-muted">{ct(`cv.class.${klass}`)}</span> <span className="dim">{ct('cv.class.note')}</span>
            </dd>
          </div>
        )}
      </dl>
    </Panel>
  )
}
