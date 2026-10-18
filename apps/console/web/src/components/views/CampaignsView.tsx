/**
 * Incidents: which burst is a campaign, and the evidence behind it.
 *
 * The radar's output on the campaign world, read from the committed fixture through two admin routes:
 * the incident list and campaign table first, then one incident at a time with what its three panels
 * draw. Nothing here starts an investigation or an action, polls, or calls Gemini; the view inherits
 * the shell's SYNTHETIC chip and adds a badge to every figure instead of a banner of its own.
 *
 * Selection follows the design's joins: an incident's campaigns are the snapshots that name it, in id
 * order. When exactly one current snapshot holds it, that one is shown; when two different campaigns
 * do, the analyst chooses, and nothing is picked for them.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { getCampaignIncident, getCampaigns } from '../../lib/api'
import type { CampaignIncident, CampaignsList, RankBy } from '../../lib/campaigns'
import { campaignsHolding, evalFor, rankIncidents, soleCampaign } from '../../lib/campaigns'
import { useCT } from '../../lib/campaignStrings'
import { useT } from '../../lib/i18n'
import { Badge, Panel } from '../primitives'
import { AttemptTimeline } from '../campaigns/AttemptTimeline'
import { CampaignActions } from '../campaigns/CampaignActions'
import { CampaignMap } from '../campaigns/CampaignMap'
import { CampaignTable } from '../campaigns/CampaignTable'
import { EvalSummary } from '../campaigns/EvalSummary'
import { EvidenceGraph } from '../campaigns/EvidenceGraph'
import { IncidentList, IncidentSummary, type Scope } from '../campaigns/IncidentRail'
import { PayeeEntities } from '../campaigns/PayeeEntities'
import '../campaigns/campaigns.css'

export function CampaignsView() {
  const { t } = useT()
  const ct = useCT()
  const [list, setList] = useState<CampaignsList | null>(null)
  const [listError, setListError] = useState<string | null>(null)
  const [selected, setSelected] = useState<string | null>(null)
  const [chosen, setChosen] = useState<string | null>(null)
  const [details, setDetails] = useState<Record<string, CampaignIncident>>({})
  const [lastShown, setLastShown] = useState<CampaignIncident | null>(null)
  const [detailError, setDetailError] = useState<string | null>(null)
  const [rankBy, setRankBy] = useState<RankBy>('surprise')
  const [scope, setScope] = useState<Scope>('all')
  const selectedRef = useRef<string | null>(null)
  const detailRequest = useRef(0)

  const selectIncident = useCallback((incidentId: string, campaignId: string | null, campaigns: CampaignsList['campaigns']) => {
    if (selectedRef.current !== incidentId) setDetailError(null)
    selectedRef.current = incidentId
    setSelected(incidentId)
    setChosen(campaignId ?? soleCampaign(campaignsHolding(incidentId, campaigns)))
  }, [])

  const loadList = useCallback(async () => {
    setListError(null)
    try {
      const body = await getCampaigns()
      setList(body)
      const top = rankIncidents(body.incidents, 'surprise', body.campaigns, body.evaluation)[0]
      if (body.available && top) selectIncident(top.incident_id, null, body.campaigns)
    } catch (err) {
      setListError((err as Error).message)
    }
  }, [selectIncident])

  useEffect(() => {
    void loadList()
  }, [loadList])

  const loadDetail = useCallback(async (incidentId: string) => {
    const request = ++detailRequest.current
    const isCurrent = () => selectedRef.current === incidentId && detailRequest.current === request
    setDetailError(null)
    try {
      const body = await getCampaignIncident(incidentId)
      if (!isCurrent()) return
      if (!body.available || !body.incident) throw new Error(body.reason || 'cv.unavailable')
      setDetails((previous) => ({ ...previous, [incidentId]: body }))
      setLastShown(body)
    } catch (err) {
      if (isCurrent()) setDetailError((err as Error).message)
    }
  }, [])

  useEffect(() => {
    if (selected && !details[selected]) void loadDetail(selected)
  }, [details, loadDetail, selected])

  const ranked = useMemo(
    () => (list ? rankIncidents(list.incidents, rankBy, list.campaigns, list.evaluation) : []),
    [list, rankBy],
  )
  const classes = useMemo(
    () => new Map((list?.evaluation?.incidents ?? []).map((row) => [row.incident_id, row.incident_class as string])),
    [list],
  )

  if (listError) {
    return (
      <div className="note bad">
        {listError}{' '}
        <button className="sm" onClick={() => void loadList()}>
          {ct('cv.retry')}
        </button>
      </div>
    )
  }
  if (!list) return <div className="loading">{t('loading')}</div>
  if (!list.available) {
    return (
      <Panel title={ct('cv.unavailable')} badge="NO DATA">
        <p className="cv-sub">{list.reason}</p>
        <button className="sm" onClick={() => void loadList()}>
          {ct('cv.retry')}
        </button>
      </Panel>
    )
  }

  const campaigns = list.campaigns
  const inScope = chosen ? campaigns.find((c) => c.campaign_id === chosen)?.incident_ids ?? [] : []
  const visible = scope === 'campaign' && chosen ? ranked.filter((i) => inScope.includes(i.incident_id)) : ranked
  const incident = list.incidents.find((i) => i.incident_id === selected) ?? null
  const holding = selected ? campaignsHolding(selected, campaigns) : []
  const fresh = selected ? details[selected] ?? null : null
  const shown = fresh ?? (detailError ? lastShown : null)
  const stale = !fresh && shown !== null
  const shownIncident = shown?.incident ?? null
  const attemptsById = new Map((shown?.attempts ?? []).map((a) => [a.attempt_id, a]))
  const incidentAttempts = shownIncident ? shownIncident.attempt_ids.flatMap((id) => attemptsById.get(id) ?? []) : []
  const campaign = shown?.campaigns.find((c) => c.campaign_id === chosen) ?? null

  const pickCampaign = (campaignId: string) => {
    const own = campaigns.find((c) => c.campaign_id === campaignId)
    const top = ranked.find((i) => own?.incident_ids.includes(i.incident_id))
    if (top) selectIncident(top.incident_id, campaignId, campaigns)
    setScope('campaign')
  }

  return (
    <>
      <p className="cv-lede">{ct('cv.detection')}</p>
      <CampaignTable campaigns={campaigns} evaluation={list.evaluation} selected={chosen} onPick={pickCampaign} />

      <div className="cv-layout">
        <aside className="cv-rail">
          <IncidentList
            incidents={visible}
            campaigns={campaigns}
            classes={classes}
            selected={selected}
            onSelect={(id) => selectIncident(id, null, campaigns)}
            rankBy={rankBy}
            onRankBy={setRankBy}
            scope={scope}
            onScope={setScope}
            scopeCount={inScope.length}
            total={ranked.length}
            hasCampaign={chosen !== null}
          />
          {incident && (
            <IncidentSummary incident={incident} holding={holding} chosen={chosen} onChoose={setChosen} klass={classes.get(incident.incident_id)} />
          )}
          <EvalSummary evaluation={list.evaluation} scored={evalFor(chosen, list.evaluation)} chosen={chosen} />
        </aside>

        <div className={`cv-panels${stale ? ' cv-stale' : ''}`}>
          {detailError && (
            <div className="note bad cv-wide" style={{ marginBottom: 12 }}>
              {ct('cv.stale')} {ct(detailError)}{' '}
              <button className="sm" onClick={() => selected && void loadDetail(selected)}>
                {ct('cv.retry')}
              </button>
            </div>
          )}
          {!shown && !detailError && <div className="loading cv-wide">{t('loading')}</div>}
          {shown && shownIncident && (
            <>
              <div>
                <Panel title={ct('cv.map')} badge="SYNTHETIC">
                  <CampaignMap attempts={incidentAttempts} />
                  <p className="cv-sub">{ct('cv.map.legend')}</p>
                  <p className="cv-sub">{ct('cv.map.note')}</p>
                </Panel>
              </div>
              <div>
                <Panel
                  title={ct('cv.timeline')}
                  badge="SYNTHETIC"
                  right={
                    <span className="cv-chips">
                      <Badge kind="RULE" /> <span className="dim">{ct('cv.firing')}</span>
                    </span>
                  }
                >
                  <AttemptTimeline incident={shownIncident} attempts={incidentAttempts} firings={shown.firings} />
                  <p className="cv-sub">{ct('cv.band.note')}</p>
                </Panel>
              </div>
              <div className="cv-wide">
                <Panel title={ct('cv.graph')} badge="RULE" question={campaign?.campaign_id}>
                  {campaign ? (
                    <>
                      <EvidenceGraph campaign={campaign} attempts={attemptsById} />
                      <PayeeEntities campaign={campaign} attempts={attemptsById} />
                    </>
                  ) : (
                    <p className="cv-sub">{shown.campaigns.length === 0 ? ct('cv.nocampaign') : ct('cv.choose')}</p>
                  )}
                </Panel>
              </div>
            </>
          )}
          <div className="cv-wide">
            <CampaignActions detail={shown} attempts={incidentAttempts} />
          </div>
        </div>
      </div>
    </>
  )
}
