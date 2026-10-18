/**
 * The audit trail: what the deployed service actually answered.
 *
 * Everything else in this console is the replay - what the rules would decide about the seed
 * world, deterministic and the same every time, with only two of the nine codes able to fire.
 * This is the other half. Real calls carry call state, SIM swaps and scam scores, so rules the
 * seed can never trigger appear here, and so does every route that is not /v1/risk/score.
 *
 * It polls rather than streams. Five seconds is fast enough to feel live while a demo is running
 * and slow enough that a console left open on a second monitor is not a cost; the poll stops when
 * the tab is hidden and when the operator pauses it. This is safe to put on a timer because it is
 * a database read - the Gemini routes never are.
 *
 * Facets count the page that was fetched rather than the collection, and the screen says so.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import { getAudit } from '../../lib/api'
import type { AuditPage, AuditRow } from '../../lib/types'
import { agoPrecise, dhakaTime, digits, n, taka } from '../../lib/format'
import { label } from '../../lib/i18n'
import { Icon } from '../Wordmark'
import { useT } from '../../lib/i18n'
import { usePoll, useNow } from '../../lib/ui'
import { eventOf, outcomeMark } from '../../lib/events'
import { Chip, Panel, Explainer } from '../primitives'
import { ShortId } from '../ShortId'
import { AuditDrawer } from '../AuditDrawer'

const POLL_MS = 5000
/* Small enough that opening the view is instant on a collection that will only grow. More is one
   click away, and the poll brings new rows in regardless of how far down you have paged. */
const PAGE = 50
const NEW_FOR_MS = 6000

export function LogsView({ onOpenAccount }: { onOpenAccount: (acctId: string) => void }) {
  const { t, lang } = useT()
  const now = useNow(1000)

  const [rows, setRows] = useState<AuditRow[]>([])
  const [page, setPage] = useState<AuditPage | null>(null)
  const [live, setLive] = useState(true)
  const [fetchedAt, setFetchedAt] = useState<number | null>(null)
  const [kind, setKind] = useState<string | null>(null)
  const [decision, setDecision] = useState<string | null>(null)
  const [selected, setSelected] = useState<AuditRow | null>(null)
  const [busy, setBusy] = useState(false)
  const [ended, setEnded] = useState(false)
  const arrived = useRef<Map<string, number>>(new Map())

  const newest = useRef<string | null>(null)

  /**
   * One fetch, two meanings. Without `since` it is the first page; with it, only what arrived
   * after the newest row already on screen - which is usually nothing, and never three hundred
   * documents re-read to discover that.
   */
  const pull = useCallback(async (mode: 'first' | 'poll') => {
    try {
      const payload = await getAudit(PAGE, undefined, mode === 'poll' ? newest.current ?? undefined : undefined)
      setFetchedAt(Date.now())
      if (!payload.available) {
        setPage(payload)
        return
      }
      if (mode === 'first') setPage(payload)
      if (payload.rows.length === 0) return
      setRows((current) => {
        const known = new Set(current.map((row) => row.id))
        const fresh = payload.rows.filter((row) => !known.has(row.id))
        if (fresh.length === 0) return current
        if (current.length > 0) {
          const stamp = Date.now()
          fresh.forEach((row) => arrived.current.set(row.id, stamp))
        }
        const merged = [...fresh, ...current]
        newest.current = merged[0]?.at ?? newest.current
        return merged
      })
    } catch (err) {
      setPage({ available: false, error: (err as Error).message, rows: [], facets: {}, window: null })
    }
  }, [])

  useEffect(() => {
    void pull('first')
  }, [pull])
  usePoll(() => void pull('poll'), POLL_MS, live)

  const older = async () => {
    const oldest = rows[rows.length - 1]?.at
    if (!oldest) return
    setBusy(true)
    try {
      const next = await getAudit(PAGE, oldest)
      setRows((current) => {
        const known = new Set(current.map((row) => row.id))
        return [...current, ...next.rows.filter((row) => !known.has(row.id))]
      })
      setEnded(next.rows.length < PAGE)
    } catch (err) {
      // The `finally` returned the button to its idle state and said nothing, so a failed page
      // read looked exactly like reaching the end of the collection.
      setPage((current) => ({ ...(current ?? { rows: [], facets: {}, window: null }), available: false, error: (err as Error).message }))
    } finally {
      setBusy(false)
    }
  }

  const visible = rows.filter((row) => (!kind || row.kind === kind) && (!decision || row.decision === decision))

  /* Counted here rather than on the server: these describe the rows on screen, which is the only
     denominator a reader can check. A server-side count over the whole collection would be a
     bigger number about a different set. */
  const count = (field: 'kind' | 'decision') => {
    const out = new Map<string, number>()
    for (const row of rows) {
      const value = row[field]
      if (value) out.set(value, (out.get(value) ?? 0) + 1)
    }
    return [...out.entries()].sort((a, b) => b[1] - a[1])
  }
  const kinds = count('kind')
  const decisions = count('decision')

  if (page && !page.available) {
    return (
      <Panel title={t('logs.title')} question={t('logs.q')} info="audit">
        <div className="note bad" role="alert">
          <Icon name="error" />
          <div>
            <b>{t('logs.unavailable')}</b>
            <div className="mono">{page.error}</div>
            <div>{t('error.next')}</div>
            <button className="sm" onClick={() => void pull('first')}>
              <Icon name="refresh" />
              {t('action.retry')}
            </button>
          </div>
        </div>
        <Explainer>{t('logs.note')}</Explainer>
      </Panel>
    )
  }

  return (
    <>
      <Panel
        title={t('logs.title')}
        question={t('logs.q')}
        badge="RULE"
        info="audit"
        right={
          <div className="row">
            <button className={`sm${live ? ' on' : ''}`} aria-pressed={live} onClick={() => setLive(!live)}>
              {live ? <span className="pulse" aria-hidden="true" /> : <Icon name="pause_circle" />}
              {live ? t('logs.live') : t('logs.paused')}
            </button>
            {fetchedAt && (
              <span className="chip t-muted">
                {t('logs.updated')} {n(Math.max(0, Math.round((now - fetchedAt) / 1000)))}{t('unit.seconds')}
              </span>
            )}
            <span className="chip t-muted">
              {n(rows.length)} {t('logs.returned')}
            </span>
          </div>
        }
      >
        <div className="toolbar">
          <button className={`sm${kind === null ? ' on' : ''}`} onClick={() => setKind(null)}>
            {t('logs.allkinds')}
          </button>
          {kinds.map(([name, count]) => (
            <button
              key={name}
              className={`sm kind-${eventOf(name).tone}${kind === name ? ' on' : ''}`}
              onClick={() => setKind(kind === name ? null : name)}
              title={name}
            >
              {eventOf(name).label[lang === 'bn' ? 1 : 0]} <span className="dim">{n(count)}</span>
            </button>
          ))}
        </div>

        {decisions.length > 0 && (
          <div className="toolbar">
            <button className={`sm${decision === null ? ' on' : ''}`} onClick={() => setDecision(null)}>
              {t('logs.alldecisions')}
            </button>
            {decisions.map(([name, count]) => (
              <button
                key={name}
                className={`sm${decision === name ? ' on' : ''}`}
                onClick={() => setDecision(decision === name ? null : name)}
              >
                <span className={`mark t-${outcomeMark(name).tone}`}>{outcomeMark(name).mark}</span>{' '}
                {label(t, 'decisions', name)} <span className="dim">{n(count)}</span>
              </button>
            ))}
          </div>
        )}

        <div className="table-wrap">
          <table className="logs-table">
            <thead>
              <tr>
                <th>{t('logs.when')}</th>
                <th>{t('logs.ago')}</th>
                <th>{t('logs.event')}</th>
                <th>{t('logs.who')}</th>
                <th>{t('logs.outcome')}</th>
                <th>{t('logs.txn')}</th>
                <th>{t('logs.flags')}</th>
                <th>{t('logs.model')}</th>
                <th className="num">{t('logs.took')}</th>
              </tr>
            </thead>
            <tbody>
              {visible.map((row) => {
                const stamp = arrived.current.get(row.id)
                const isNew = stamp !== undefined && now - stamp < NEW_FOR_MS
                return (
                  <tr
                    key={row.id}
                    className={`clickable${isNew ? ' fresh' : ''}${selected?.id === row.id ? ' selected' : ''}`}
                    onClick={() => setSelected(row)}
                  >
                    <td className="mono dim nowrap">
                      {row.at ? dhakaTime(row.at).slice(-12) : '—'}
                      {isNew && <span className="newdot">{t('logs.new')}</span>}
                    </td>
                    <td className="mono nowrap">
                      {row.at ? agoPrecise(row.at, lang, now) : '—'}
                    </td>
                    <td>
                      <Chip kind={eventOf(row.kind).tone}>{eventOf(row.kind).label[lang === 'bn' ? 1 : 0]}</Chip>
                      <div className="mono dim">{row.kind}</div>
                    </td>
                    <td className="mono who-cell">
                      <div>{row.uid ?? '—'}</div>
                      {row.session_id && <ShortId value={row.session_id} />}
                    </td>
                    <td>
                      {/* Three chips, a number and a code list made this the busiest column in
                          the table for what is really three facts in order of importance: what
                          was decided, how risky it was, and why. Said in that order, each on its
                          own line, with one accent - the decision - and the rest quiet. */}
                      {row.decision ? (
                        <>
                          <div className={`outcome-line t-text-${outcomeMark(row.decision).tone}`}>
                            <span className="mark">{outcomeMark(row.decision).mark}</span>
                            <b>{label(t, 'decisions', row.decision)}</b>
                          </div>
                          {(row.band || row.risk_score !== null) && (
                            <div className="outcome-sub mono">
                              {row.band && label(t, 'band', row.band)}
                              {row.band && row.risk_score !== null && ' · '}
                              {row.risk_score !== null && digits(String(row.risk_score))}
                            </div>
                          )}
                          {row.reason_codes.length > 0 && (
                            <div className="outcome-codes mono">
                              {row.reason_codes.map((code) => (
                                <span key={code}>{code}</span>
                              ))}
                            </div>
                          )}
                        </>
                      ) : (
                        <span className="dim">{row.verdict ?? '—'}</span>
                      )}
                    </td>
                    <td className="txn-cell">
                      {row.txn_type ? (
                        <>
                          <span className="mono">{row.txn_type}</span>
                          {row.amount_bdt ? <span className="dim amount"> {taka(row.amount_bdt, lang)}</span> : null}
                          {row.to_account && (
                            <div
                              className="mono linkish"
                              onClick={(event) => {
                                event.stopPropagation()
                                onOpenAccount(row.to_account!)
                              }}
                            >
{'→ '}{row.to_account}
                            </div>
                          )}
                        </>
                      ) : (
                        <span className="dim">—</span>
                      )}
                    </td>
                    <td className="flags-cell">
                      {row.flags.length === 0 ? (
                        <span className="dim">—</span>
                      ) : (
                        row.flags.map((flag) => {
                          // Plain. These are notes on a row - what was switched on and what it was
                          // set to - not verdicts, and a chip each gave eleven of them the weight
                          // of a decision. The value may not be dropped either:
                          // `app_safety_verdict=BLOCK` is the whole reason that payment stopped.
                          const cut = flag.indexOf('=')
                          return (
                            <div key={flag} className="flag">
                              <span className="flag-name">{cut === -1 ? flag : flag.slice(0, cut)}</span>
                              {cut !== -1 && <span className="flag-value">{flag.slice(cut + 1)}</span>}
                            </div>
                          )
                        })
                      )}
                    </td>
                    <td className="mono dim">{row.model_version ?? '—'}</td>
                    <td className="num mono">{row.processing_ms !== null ? n(Math.round(row.processing_ms)) : '—'}</td>
                  </tr>
                )
              })}
              {visible.length === 0 && (
                <tr>
                  <td colSpan={9} className="empty">
                    <Icon name="description" />
                    <p>{t('logs.none')}</p>
                    {(kind !== null || decision !== null) && (
                      <button
                        className="sm"
                        onClick={() => {
                          setKind(null)
                          setDecision(null)
                        }}
                      >
                        {t('logs.showall')}
                      </button>
                    )}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>

        <div className="toolbar pager">
          <span className="dim">
            {n(visible.length)} {t('logs.of')} {n(rows.length)} {t('logs.loaded')}
          </span>
          <span className="spacer" />
          <span className="dim">{t('logs.facetnote')}</span>
          <button className="sm" onClick={() => void older()} disabled={busy || ended}>
            {busy ? t('loading') : ended ? t('logs.end') : `${t('logs.more')} ${n(PAGE)}`}
          </button>
        </div>

        <Explainer>{t('logs.note')}</Explainer>
      </Panel>

      {selected && (
        <AuditDrawer row={selected} onClose={() => setSelected(null)} onOpenAccount={onOpenAccount} />
      )}
    </>
  )
}
