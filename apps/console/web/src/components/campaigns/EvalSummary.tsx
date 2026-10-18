/**
 * The evaluation, beside the incident and never inside the detector.
 *
 * Money is a Rate: retained_by_flag of allowed_by_flag, so the share never appears without its base,
 * and "n/a" when nothing was credited by the flag. It is the selected campaign's, joined by
 * detected_campaign_id, at that campaign's own flag time, which is printed. Measures read the way the
 * model cards read their eval files: pass, fail, n/a, and anything else is NO DATA, never a pass. The
 * caveat is shown verbatim. Everything here is SYNTHETIC: outcomes against generated truth.
 */

import { n } from '../../lib/format'
import type { CampaignEvaluation, EvalCampaign } from '../../lib/campaigns'
import { gateState, MEASURE_TONE, measureLabel, stamp } from '../../lib/campaigns'
import { useCT } from '../../lib/campaignStrings'
import { Panel, Rate, Tile } from '../primitives'

const taka = (value: number | null | undefined) => (value === null || value === undefined ? '—' : `৳${n(value)}`)

function Money({ scored, chosen }: { scored: EvalCampaign | null; chosen: string | null }) {
  const ct = useCT()
  if (!chosen) return <Tile label={ct('cv.money')} value={ct('cv.nodata')} sub={ct('cv.money.pick')} badge="NO DATA" small />
  if (!scored) return <Tile label={ct('cv.money')} value={ct('cv.nodata')} sub={ct('cv.money.noeval')} badge="NO DATA" small />
  const credited = scored.allowed_by_flag ?? 0
  return (
    <>
      {credited > 0 && scored.retained_by_flag !== null ? (
        <Rate
          label={`${ct('cv.money')} (${ct('cv.credited')})`}
          value={scored.retained_fraction}
          numerator={scored.retained_by_flag}
          denominator={credited}
          badge="SYNTHETIC"
        />
      ) : (
        <Tile label={ct('cv.money')} value="n/a" sub={ct('cv.money.na')} badge="SYNTHETIC" />
      )}
      <p className="cv-sub">
        {ct('cv.cashedout')} <b>{taka(scored.cashed_out_by_flag)}</b>
        <br />
        {ct('cv.afterflag')} <b>{taka(scored.future_allowed_after_flag)}</b>
        <br />
        {ct('cv.flag')} <span className="mono">{scored.flag_ts ? stamp(scored.flag_ts) : '—'}</span>
        {scored.time_to_flag_min !== null && (
          <>
            {' '}
            · <b>{scored.time_to_flag_min.toFixed(1)}</b> {ct('cv.ttf')}
          </>
        )}
      </p>
      <p className="cv-sub">{ct('cv.money.note')}</p>
    </>
  )
}

export function EvalSummary({
  evaluation,
  scored,
  chosen,
}: {
  evaluation: CampaignEvaluation | null | undefined
  scored: EvalCampaign | null
  chosen: string | null
}) {
  const ct = useCT()
  if (!evaluation) {
    return (
      <Panel title={ct('cv.measures')} badge="NO DATA">
        <p className="cv-sub">{ct('cv.nodata')}: eval/results/campaign.json</p>
      </Panel>
    )
  }
  const gates = gateState(evaluation.measures)
  return (
    <Panel title={ct('cv.measures')} badge="SYNTHETIC">
      <div className="cv-stack">
        <Money scored={scored} chosen={chosen} />
        <Tile label={ct('cv.inside')} value={ct('cv.nodata')} sub={ct('cv.inside.sub')} badge="NO DATA" small />
      </div>
      <div className="table-wrap cv-mini" style={{ marginTop: 12 }}>
        <table>
          <thead>
            <tr>
              <th>{ct('cv.measure')}</th>
              <th className="num">{ct('cv.value')}</th>
              <th>{ct('cv.target')}</th>
              <th>{ct('cv.status')}</th>
            </tr>
          </thead>
          <tbody>
            {Object.entries(evaluation.measures).map(([name, m]) => (
              <tr key={name}>
                <td className="mono">{name}</td>
                <td className="num">{m.value === null ? '—' : Number.isInteger(m.value) ? m.value : m.value.toFixed(3)}</td>
                <td className="mono">{m.target}</td>
                <td>
                  <span className={`badge t-${MEASURE_TONE[m.status] ?? 'muted'}`}>{measureLabel(m.status)}</span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="cv-sub">
        {gates.state === 'passed' && `${ct('cv.gates.passed')} (${gates.total})`}
        {gates.state === 'failed' && `${ct('cv.gates.failed')}: ${gates.names.join(', ')}`}
        {gates.state === 'unmeasured' && `${ct('cv.gates.unmeasured')}: ${gates.names.join(', ')}`}
        {gates.state === 'none' && ct('cv.nodata')}
      </p>
      {evaluation.caveat && (
        <p className="cv-sub">
          <b>{ct('cv.caveat')}.</b> {evaluation.caveat}
        </p>
      )}
      {evaluation.payee_note && (
        <p className="cv-sub">
          <b>{ct('cv.payeenote')}.</b> {evaluation.payee_note}
        </p>
      )}
      <details className="cv-details">
        <summary>{ct('cv.source')}</summary>
        <p className="cv-mono">
          {evaluation.source} · {evaluation.generated_at ?? '—'}
          <br />
          seed {evaluation.seed_checksum ?? '—'}
        </p>
        <p className="cv-mono">
          {Object.entries(evaluation.config)
            .map(([key, value]) => `${key}=${JSON.stringify(value)}`)
            .join(' · ')}
        </p>
      </details>
    </Panel>
  )
}
