/**
 * What Case Zero knows, and what the payment path did about it.
 *
 * The gate ladder says of G4: "the watch-list exists but is not read at payment time." That is a
 * claim in a tooltip. This screen turns it into a count, by joining every account an investigation
 * has implicated to the payments the rule engine actually scored. The answer is uncomfortable, and
 * that is the point of putting it on a screen.
 *
 * Case Zero sends no CORS headers, so everything here comes through this service rather than
 * straight from the browser.
 */

import { Fragment, useEffect, useRef, useState } from 'react'
import { getCaseFile, getCasezeroHealth, getReplay, getReplayFile, getRingGraph, getWatchlist } from '../../lib/api'
import type { CaseFile, CaseZeroHealth, ReplayEvent, RingGraphData, Watchlist } from '../../lib/types'
import { digits, fx, n, pct, taka } from '../../lib/format'
import { Icon } from '../Wordmark'
import { useT } from '../../lib/i18n'
import { Chip, Panel, Tile, Explainer } from '../primitives'
import { RingGraph } from '../RingGraph'
import { Info } from '../Info'
import { CaseFileView } from '../CaseFile'

export function CasesView({ onOpenAccount }: { onOpenAccount: (acctId: string) => void }) {
  const { t, lang } = useT()
  const [health, setHealth] = useState<CaseZeroHealth | null>(null)
  const [list, setList] = useState<Watchlist | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [open, setOpen] = useState<string | null>(null)
  const [replay, setReplay] = useState<ReplayEvent[] | null>(null)
  const [ring, setRing] = useState<RingGraphData | null>(null)
  const [loadingReplay, setLoadingReplay] = useState(false)
  const [replayFile, setReplayFile] = useState<CaseFile | null>(null)
  // The live case file opened from a watch-list row, and its error (a case Case Zero no longer holds is a 404).
  const [caseFile, setCaseFile] = useState<CaseFile | null>(null)
  const [caseError, setCaseError] = useState<string | null>(null)
  const [loadingCase, setLoadingCase] = useState<string | null>(null)
  // The case file opens as a panel below the watch-list, usually off-screen: bring it into view, or the click
  // looks like it did nothing (it did, live on 2026-10-17: four 200s and a page that never moved).
  const caseRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!caseFile && !caseError) return
    const still = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches
    caseRef.current?.scrollIntoView({ behavior: still ? 'auto' : 'smooth', block: 'start' })
  }, [caseFile, caseError])

  useEffect(() => {
    getCasezeroHealth().then(setHealth).catch(() => setHealth(null))
    getWatchlist()
      .then(setList)
      .catch((err: Error) => setError(err.message))
    getRingGraph().then(setRing).catch(() => setRing(null))
  }, [])

  const openCase = async (caseId: string) => {
    setLoadingCase(caseId)
    setCaseError(null)
    try {
      setCaseFile(await getCaseFile(caseId))
    } catch (err) {
      setCaseFile(null)
      setCaseError((err as Error).message)
    } finally {
      setLoadingCase(null)
    }
  }

  const loadReplay = async () => {
    setLoadingReplay(true)
    try {
      const [events, file] = await Promise.all([getReplay(), getReplayFile().catch(() => null)])
      setReplay(events)
      setReplayFile(file)
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setLoadingReplay(false)
    }
  }

  const gap = list?.gap

  return (
    <>
      <Panel
        title={t('cases.title')}
        question={t('cases.q')}
        info="casezero"
        right={
          health?.reachable ? (
            <Chip kind="good">
              <Icon name="check_circle" />
              {health.model} · {n(health.cases ?? 0)} {t('cases.held')}
            </Chip>
          ) : (
            <Chip kind="bad">
              <Icon name="error" />
              {t('cases.unreachable')}
            </Chip>
          )
        }
      >
        {error && (
          <div className="note bad" role="alert">
            <Icon name="error" />
            <div>
              {error}
              <div>{t('error.next')}</div>
            </div>
          </div>
        )}
        {gap && (
          <>
            <div className="grid g-4">
              <Tile
                label={t('cases.watchlisted')}
                value={n(gap.watchlisted_accounts)}
                sub={t('cases.watchlisted.sub')}
                badge="MODEL"
              />
              <Tile
                label={t('cases.payments')}
                value={n(gap.payments_to_watchlisted)}
                sub={taka(gap.amount_bdt, lang)}
                badge="RULE"
                info="gap"
              />
              <Tile
                label={t('cases.stopped')}
                value={n(gap.stopped_by_rules)}
                sub={`${pct(gap.stopped_share ?? 0, 0)} ${t('cases.ofthose')}`}
                badge="RULE"
              />
              <Tile
                label={t('cases.missed')}
                value={n(gap.missed)}
                sub={t('cases.missed.sub')}
                badge="RULE"
              />
            </div>
            <div className="note bad">
              <Icon name="error" />
              <div>
                <b>{t('cases.gap.title')}</b> {t('cases.gap.body')}
              </div>
            </div>
          </>
        )}
      </Panel>

      {list && (
        <Panel
          title={t('cases.watchlist')}
          question={t('cases.watchlist.q')}
          badge="MODEL"
          right={<span className="chip t-muted">{list.version}</span>}
        >
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>{t('accounts.account')}</th>
                  <th>{t('accounts.role')}</th>
                  <th className="num">
                    p(mule) <Info k="disagree" />
                  </th>
                  <th className="num">{t('cases.col.payments')}</th>
                  <th className="num">{t('cases.col.stopped')}</th>
                  <th className="num">{t('drawer.amount')}</th>
                  <th>{t('cases.col.case')}</th>
                </tr>
              </thead>
              <tbody>
                {list.payees.map((row) => {
                  const leaked = row.payments_to_this_payee > row.stopped_by_rules
                  return (
                    <Fragment key={row.acct_id}>
                      <tr
                        className="clickable"
                        onClick={() => setOpen(open === row.acct_id ? null : row.acct_id)}
                      >
                        <td className="mono">{row.acct_id}</td>
                        <td>
                          <Chip kind="violet">{row.role}</Chip>
                        </td>
                        <td className="num">
                          <Chip kind={row.model_score >= 0.8 ? 'bad' : row.model_score >= 0.1 ? 'warn' : 'muted'}>
                            {fx(row.model_score, 4)}
                          </Chip>
                        </td>
                        <td className="num">{n(row.payments_to_this_payee)}</td>
                        <td className="num">
                          <span className={leaked ? 't-bad chip' : 't-good chip'}>
                            <Icon name={leaked ? 'error' : 'check_circle'} />
                            {n(row.stopped_by_rules)}
                          </span>
                        </td>
                        <td className="num">{taka(row.amount_bdt, lang)}</td>
                        <td className="mono dim">{row.case_id}</td>
                      </tr>
                      {open === row.acct_id && (
                        <tr>
                          <td colSpan={7} className="expanded">
                            <div className="dim">{t('cases.facts')}</div>
                            <ul className="facts">
                              {row.facts.map((fact) => (
                                <li key={fact}>{fact}</li>
                              ))}
                            </ul>
                            <div className="toolbar">
                              <Chip kind={row.analyst_approved ? 'good' : 'warn'}>
                                {row.analyst_approved ? t('cases.approved') : t('cases.unapproved')}
                              </Chip>
                              <button className="sm" onClick={() => void openCase(row.case_id)} disabled={loadingCase === row.case_id}>
                                {loadingCase === row.case_id ? t('loading') : t('casefile.open')}
                              </button>
                              <button className="sm" onClick={() => onOpenAccount(row.acct_id)}>
                                {t('live.open_account')}
                              </button>
                            </div>
                          </td>
                        </tr>
                      )}
                    </Fragment>
                  )
                })}
              </tbody>
            </table>
          </div>
          <Explainer>{t('cases.watchlist.note')}</Explainer>
        </Panel>
      )}

      {(caseFile || caseError) && (
        <div ref={caseRef} className="scroll-anchor">
        <Panel
          title={t('casefile.title')}
          question={t('casefile.q')}
          badge="MODEL"
          right={
            <button className="sm" onClick={() => { setCaseFile(null); setCaseError(null) }}>
              {t('casefile.close')}
            </button>
          }
        >
          {caseError && (
            <div className="note bad" role="alert">
              <Icon name="error" />
              <div>{caseError}</div>
            </div>
          )}
          {caseFile && <CaseFileView file={caseFile} onOpenAccount={onOpenAccount} />}
        </Panel>
        </div>
      )}

      {ring && (
        <Panel
          title={t('ring.title')}
          question={t('ring.q')}
          badge={ring.badge}
          info="ring"
          right={
            <span className="chip t-muted">
              {ring.case_id} · {t('ring.seed')} {digits(String(ring.seed))}
            </span>
          }
        >
          <div className="grid g-4 gap-bottom">
            <Tile label={t('ring.accounts')} value={n(ring.counts.nodes)} sub={`${n(ring.counts.watchlisted)} ${t('ring.onlist')}`} badge="MODEL" />
            <Tile label={t('ring.links')} value={n(ring.counts.edges)} sub={`${n(ring.counts.money_edges)} ${t('ring.money')}`} badge="MODEL" />
            <Tile label={t('ring.moved')} value={taka(ring.counts.money_bdt, lang)} sub={t('ring.moved.sub')} badge="MODEL" />
            <Tile label={t('ring.calls')} value={n(ring.counts.tool_calls)} sub={ring.model} badge="MODEL" />
          </div>
          <RingGraph data={ring} onOpenAccount={onOpenAccount} />
          <Explainer>{t('ring.note')}</Explainer>
        </Panel>
      )}

      <Panel
        title={t('cases.replay')}
        question={t('cases.replay.q')}
        info="replay"
        right={
          <button className="sm" onClick={() => void loadReplay()} disabled={loadingReplay}>
            {loadingReplay ? t('loading') : t('cases.replay.load')}
          </button>
        }
      >
        {!replay && <p className="panel-note">{t('cases.replay.hint')}</p>}
        {replayFile && <CaseFileView file={replayFile} onOpenAccount={onOpenAccount} />}
        {replay && (
          <details className="explainer">
            <summary>{t('casefile.raw')} ({n(replay.length)})</summary>
          <div className="trace">
            {replay.map((event, index) => (
              <div className="step" key={index}>
                <span className="k">{event.type}</span>{' '}
                {event.type === 'tool_call'
                  ? `${event.call_id ?? ''} ${event.name ?? ''} ${JSON.stringify(event.args ?? {})}`
                  : event.type === 'tool_result'
                    ? `${event.call_id ?? ''} ${event.ok === false ? 'failed' : 'ok'}`
                    : event.type === 'run_started'
                      ? `${event.case_id ?? ''} seed ${event.seed ?? ''} · ${event.model ?? ''}`
                      : event.type === 'done'
                        ? JSON.stringify(event).slice(0, 220)
                        : JSON.stringify(event).slice(0, 180)}
              </div>
            ))}
          </div>
          </details>
        )}
      </Panel>
    </>
  )
}
