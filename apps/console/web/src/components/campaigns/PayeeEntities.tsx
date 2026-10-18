/**
 * What sits under the graph: each payee's entities, the campaign's own figures, and the evidence.
 *
 * The table reads each payee's latest attempt in the campaign, so its entities are as of the last
 * time anyone paid it. Values an evidence triple names are bold; the rest is context and is never
 * drawn as a link. Absent entities are a dash, never a guess.
 */

import type { CampaignAttempt, RadarCampaign } from '../../lib/campaigns'
import { entityCounts, payeeProfiles, stamp } from '../../lib/campaigns'
import { useCT } from '../../lib/campaignStrings'

export function PayeeEntities({ campaign, attempts }: { campaign: RadarCampaign; attempts: Map<string, CampaignAttempt> }) {
  const ct = useCT()
  const profiles = payeeProfiles(campaign, attempts)
  const named = new Set(campaign.evidence.map(([, , entity]) => entity.slice(entity.indexOf(':') + 1)))
  const counts = entityCounts(campaign.evidence)
  const cell = (value: string | null | undefined, key: string) => {
    const values = (value ?? '').split(', ').filter(Boolean)
    return (
      <td key={key} className={`mono${values.some((v) => named.has(v)) ? ' cv-named' : ''}`}>
        {value || '—'}
      </td>
    )
  }

  return (
    <>
      <div className="table-wrap cv-mini" style={{ marginTop: 10 }}>
        <table>
          <thead>
            <tr>
              <th>{ct('cv.payee')}</th>
              <th>{ct('cv.district')}</th>
              <th>{ct('cv.kind.payee_onboarding_agent')}</th>
              <th>{ct('cv.kind.payee_sim_day')}</th>
              <th>{ct('cv.kind.payee_till')}</th>
              <th>{ct('cv.kind.payee_device')}</th>
              <th>{ct('cv.nexthop')}</th>
            </tr>
          </thead>
          <tbody>
            {campaign.payees.map((payee) => {
              const a = profiles.get(payee)
              return (
                <tr key={payee}>
                  <td className="mono">{payee}</td>
                  {cell(a?.payee_district, 'district')}
                  {cell(a?.payee_onboarding_agent, 'agent')}
                  {cell(a?.payee_sim_day, 'sim')}
                  {cell(a?.payee_till, 'till')}
                  {cell(a?.payee_devices.join(', '), 'devices')}
                  {cell(a?.payee_next_hops.join(', '), 'hops')}
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      <p className="cv-sub">{ct('cv.payeetable.note')}</p>

      <div className="cv-legend">
        <span>
          {ct('cv.syncconcrank')}{' '}
          <b>
            {campaign.synchrony.toFixed(2)} / {campaign.concentration.toFixed(1)} / {campaign.rank_score.toFixed(2)}
          </b>
        </span>
        <span>
          {ct('cv.tills')} <b className="mono">{campaign.tills.join(', ') || '—'}</b>
        </span>
        <span>
          {ct('cv.opened')} <b>{stamp(campaign.opened_at)}</b> · {ct('cv.asof')} <b>{stamp(campaign.as_of)}</b>
        </span>
      </div>

      <details className="cv-details">
        <summary>
          {ct('cv.evidence')} · {campaign.evidence.length} {ct('cv.evidence.summary')}
        </summary>
        <p className="cv-mono">{counts.map(([entity, count]) => `${entity} ×${count}`).join(' · ')}</p>
        <div className="cv-mono cv-scroll">
          {campaign.evidence.map(([source, target, entity]) => `[${source}, ${target}, ${entity}]`).join('  ')}
        </div>
        {campaign.shared_entities.length > 0 && (
          <p className="cv-mono">
            {campaign.shared_entities
              .map((s) => `${s.payees.join(' ↔ ')} · ${s.entity}${s.in_evidence ? '' : ` (${ct('cv.shared')})`}`)
              .join('; ')}
          </p>
        )}
        <p className="cv-sub">{ct('cv.graph.note')}</p>
      </details>
    </>
  )
}
