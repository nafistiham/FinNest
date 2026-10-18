/**
 * The campaigns the radar linked, ranked by its own rank_score.
 *
 * Linkage ships, so the table is RULE. The money column is eval-only (SYNTHETIC): it joins
 * campaign.json by detected_campaign_id and shows retained-at-flag with its denominator, or says
 * there is no evaluation row. A campaign whose component named more payees than the true campaign
 * carries the evaluator's own sentence under its row. Superseded snapshots are listed, not hidden.
 */

import { Fragment } from 'react'
import { n, pct } from '../../lib/format'
import { useT } from '../../lib/i18n'
import type { CampaignEvaluation, RadarCampaign } from '../../lib/campaigns'
import { evalFor, stamp } from '../../lib/campaigns'
import { useCT } from '../../lib/campaignStrings'
import { Badge, Panel } from '../primitives'

export function CampaignTable({
  campaigns,
  evaluation,
  selected,
  onPick,
}: {
  campaigns: RadarCampaign[]
  evaluation: CampaignEvaluation | null | undefined
  selected: string | null
  onPick: (campaignId: string) => void
}) {
  const ct = useCT()
  const { t } = useT()
  const current = campaigns.filter((c) => c.superseded_by === null).sort((a, b) => b.rank_score - a.rank_score)
  const earlier = campaigns.filter((c) => c.superseded_by !== null)

  return (
    <Panel title={ct('cv.campaigns')} question={ct('cv.campaigns.q')} badge="RULE">
      <div className="table-wrap cv-table">
        <table>
          <thead>
            <tr>
              <th>{ct('cv.col.campaign')}</th>
              <th>{ct('cv.col.opened')}</th>
              <th className="num">{ct('cv.col.payees')}</th>
              <th className="num">{ct('cv.col.senders')}</th>
              <th className="num">
                {t('decisions.hold')} / {t('decisions.allow')}
              </th>
              <th className="num">{ct('cv.col.sync')}</th>
              <th className="num">{ct('cv.col.conc')}</th>
              <th className="num">{ct('cv.col.rank')}</th>
              <th>
                {ct('cv.col.money')} <Badge kind="SYNTHETIC" />
              </th>
            </tr>
          </thead>
          <tbody>
            {current.map((c) => {
              const scored = evalFor(c.campaign_id, evaluation)
              const credited = scored?.allowed_by_flag ?? null
              return (
                <Fragment key={c.campaign_id}>
                  <tr className={`clickable${selected === c.campaign_id ? ' cv-on' : ''}`} onClick={() => onPick(c.campaign_id)}>
                    <td className="mono">{c.campaign_id}</td>
                    <td className="mono cv-nowrap">{stamp(c.opened_at)}</td>
                    <td className="num">{n(c.payees.length)}</td>
                    <td className="num">{n(c.senders.length)}</td>
                    <td className="num">
                      {n(c.held)} / {n(c.allowed)}
                    </td>
                    <td className="num">{c.synchrony.toFixed(2)}</td>
                    <td className="num">{c.concentration.toFixed(1)}</td>
                    <td className="num">{c.rank_score.toFixed(1)}</td>
                    <td>
                      {!scored ? (
                        <span className="dim">{ct('cv.nodata')}</span>
                      ) : credited ? (
                        <span className="mono cv-nowrap">
                          {pct(scored.retained_fraction)} · ৳{n(scored.retained_by_flag)} of ৳{n(credited)}
                        </span>
                      ) : (
                        <span className="dim">{ct('cv.money.na')}</span>
                      )}
                      {scored && (
                        <div className="dim cv-mono">
                          {ct('cv.evalmatch')} · {scored.campaign_id}
                        </div>
                      )}
                    </td>
                  </tr>
                  {scored?.payee_overreach && (
                    <tr className={selected === c.campaign_id ? 'cv-on' : undefined}>
                      <td colSpan={9} className="cv-note">
                        <Badge kind="SYNTHETIC" /> {ct('cv.payeenote')} ({ct('cv.evalonly')}): {scored.payee_overreach}.
                      </td>
                    </tr>
                  )}
                </Fragment>
              )
            })}
          </tbody>
        </table>
      </div>
      {earlier.length > 0 && (
        <p className="panel-note">
          {ct('cv.superseded')}{' '}
          {earlier.map((c) => `${c.campaign_id} → ${c.superseded_by}`).join(', ')}. {ct('cv.superseded.why')}
        </p>
      )}
    </Panel>
  )
}
