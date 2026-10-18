/**
 * What an analyst would do next, every control off.
 *
 * Detection only: this view sends no request. The four campaign actions are not built yet; each is disabled
 * with the chip that says so. Case Zero is a working console capability elsewhere, but the campaign world's
 * payees are not in the demo seed it investigates, so it is off here too and says why. The two
 * exports are local files built from the rows already on screen.
 */

import type { CampaignAttempt, CampaignIncident } from '../../lib/campaigns'
import { attemptsCsv, download } from '../../lib/campaigns'
import { useCT } from '../../lib/campaignStrings'
import { Panel } from '../primitives'

const FUTURE = ['cv.act.cool', 'cv.act.suspend', 'cv.act.warn', 'cv.act.benign'] as const

export function CampaignActions({ detail, attempts }: { detail: CampaignIncident | null; attempts: CampaignAttempt[] }) {
  const ct = useCT()
  const id = detail?.incident?.incident_id ?? 'incident'
  return (
    <Panel
      title={ct('cv.actions')}
      question={ct('cv.actions.q')}
      right={
        <>
          <button
            className="sm"
            disabled={!detail}
            onClick={() => detail && download(`finnest-synthetic-${id}.json`, JSON.stringify(detail, null, 2), 'application/json')}
          >
            {ct('cv.export.json')}
          </button>
          <button
            className="sm"
            disabled={!attempts.length}
            onClick={() => download(`finnest-synthetic-${id}-attempts.csv`, attemptsCsv(attempts), 'text/csv')}
          >
            {ct('cv.export.csv')}
          </button>
        </>
      }
    >
      <div className="cv-actions">
        <div className="cv-action">
          <button type="button" disabled title={ct('cv.act.casezero.why')}>
            {ct('cv.act.casezero')}
          </button>
          <span className="chip t-muted">{ct('cv.act.casezero.chip')}</span>
        </div>
        {FUTURE.map((key) => (
          <div className="cv-action" key={key}>
            <button type="button" disabled>
              {ct(key)}
            </button>
            <span className="chip t-warn">{ct('cv.notwired')}</span>
          </div>
        ))}
      </div>
      <p className="panel-note">{ct('cv.act.note')}</p>
    </Panel>
  )
}
