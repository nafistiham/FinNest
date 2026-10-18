/**
 * One audit document, opened beside the table rather than on a page of its own.
 *
 * The operator's question is almost always "why that outcome" while the rest of the log is still
 * in view, so this slides in on the right and the table stays where it was.
 *
 * What it shows is what was stored, not what the rules would say now. A decision is evidence: the
 * reasons are the ones the customer was given, in the language they were given, and the model
 * version is the one that produced them even if it is no longer deployed.
 */

import { useEffect, useState } from 'react'
import { getAuditDocument, getAuditInsight } from '../lib/api'
import type { AuditRow } from '../lib/types'
import { agoPrecise, dhakaTime, digits, n, taka, tone } from '../lib/format'
import { label } from '../lib/i18n'
import { useT } from '../lib/i18n'
import { useLeave } from '../lib/ui'
import { AppSafetyReport } from './AppSafetyReport'
import { GeminiInsight, type InsightState } from './GeminiInsight'
import { DrawerSkeleton, Explainer } from './primitives'
import { Icon } from './Wordmark'
import { Chip } from './primitives'
import { eventOf, outcomeMark } from '../lib/events'

type Doc = Record<string, any>

export function AuditDrawer({
  row,
  onClose,
  onOpenAccount,
}: {
  row: AuditRow
  onClose: () => void
  onOpenAccount: (acctId: string) => void
}) {
  const { t, lang } = useT()
  const [leaving, close] = useLeave(onClose)
  const [doc, setDoc] = useState<Doc | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [showRaw, setShowRaw] = useState(false)
  const [insight, setInsight] = useState<InsightState | null>(null)
  const [insightAsk, setInsightAsk] = useState(0)
  // Only a score with reasons has something to explain; the service would say so too, but asking costs a round trip.
  const explainable = row.kind === 'score' && row.reason_codes.length > 0

  useEffect(() => {
    // Clicking down a list faster than the network answers would otherwise show one row's
    // document under another row's heading - the first request resolving last wins.
    let current = true
    setDoc(null)
    setError(null)
    getAuditDocument(row.id)
      .then((payload) => current && setDoc(payload))
      .catch((err: Error) => current && setError(err.message))
    return () => {
      current = false
    }
  }, [row.id])

  useEffect(() => {
    // Gemini's reading loads beside the document, not after it: the stored row is on screen at once and the reading
    // (a model call the first time, the cache after) fills in when it comes. Same guard against a faster click.
    if (!explainable) {
      setInsight(null)
      return
    }
    let current = true
    setInsight({ status: 'loading' })
    getAuditInsight(row.id)
      .then((answer) => current && setInsight({ status: 'done', answer }))
      .catch((err: Error) => current && setInsight({ status: 'failed', message: err.message }))
    return () => {
      current = false
    }
  }, [row.id, explainable, insightAsk])

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => event.key === 'Escape' && close()
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [close])

  const inputs: Doc = doc?.inputs ?? {}
  const outputs: Doc = doc?.outputs ?? {}
  const txn: Doc = inputs.txn ?? {}
  const flags: Doc = inputs.demo_flags ?? {}
  const reasons: Doc[] = outputs.reasons ?? []
  const actions: Doc[] = outputs.actions ?? []
  /* The same mistake the server row made: `app_safety_verdict: "BLOCK"` is a string, so a filter
     that only admits `true` and positive numbers dropped the one flag that explains a block. A
     flag is anything not at its default. */
  const onFlags = Object.entries(flags).filter(
    ([, v]) => v !== false && v !== null && v !== undefined && v !== '' && v !== 0,
  )

  return (
    <>
      <div className={`scrim${leaving ? ' leaving' : ''}`} onClick={close} />
      <aside className={`drawer wide${leaving ? ' leaving' : ''}`} role="dialog" aria-modal="true">
        <div className="head">
          <div className="row">
            <Chip kind={eventOf(row.kind).tone}>{eventOf(row.kind).label[lang === 'bn' ? 1 : 0]}</Chip>
            <h2 className="drawer-title mono">{row.id.slice(0, 8)}</h2>
            <span className="dim">{row.uid}</span>
            <span className="spacer" />
            <button className="sm" onClick={close}>
              <Icon name="close" />
              {t('drawer.close')}
            </button>
          </div>
          <div className="dim">
            {dhakaTime(row.at)} · {agoPrecise(row.at, lang)} ·{' '}
            {row.processing_ms !== null ? `${n(Math.round(row.processing_ms))} ms` : '—'} ·{' '}
            <span className="mono">{row.model_version}</span>
          </div>
        </div>

        <div className="body">
          {error && <div className="note bad">{error}</div>}
          {!doc && !error && <DrawerSkeleton />}

          {doc && (
            <>
              {outputs.decision && (
                <>
                  <h3 className="drawer-h">{t('audit.outcome')}</h3>
                  <div className="row">
                    <span className={`mark big t-${outcomeMark(outputs.decision).tone}`}>
                      {outcomeMark(outputs.decision).mark}
                    </span>
                    <Chip kind={tone(outputs.decision)}>{label(t, 'decisions', outputs.decision)}</Chip>
                    {outputs.band && <Chip kind={tone(outputs.band)}>{label(t, 'band', outputs.band)}</Chip>}
                    {outputs.risk_score !== undefined && (
                      <span className="mono">{t('audit.risk')} {digits(String(outputs.risk_score))}</span>
                    )}
                  </div>
                </>
              )}

              {insight && <GeminiInsight state={insight} onRetry={() => setInsightAsk((ask) => ask + 1)} />}

              {reasons.length > 0 && (
                <>
                  <h3 className="drawer-h">{t('audit.reasons')}</h3>
                  {reasons.map((reason, index) => (
                    <div className="tile" key={index} style={{ marginBottom: 8 }}>
                      <div className="row">
                        <Chip kind="high">{reason.code}</Chip>
                        <span className="mono dim">{t('audit.weight')} {digits(String(reason.weight))}</span>
                      </div>
                      <div lang="bn" className="reason-bn">{reason.text_bn}</div>
                      <div lang="en" className="dim">{reason.text_en}</div>
                    </div>
                  ))}
                  <Explainer>{t('audit.reasons.note')}</Explainer>
                </>
              )}

              {actions.length > 0 && (
                <>
                  <h3 className="drawer-h">{t('audit.actions')}</h3>
                  <div className="row">
                    {actions.map((action, index) => (
                      <Chip key={index} kind="violet">
                        {action.type}
                        {action.params && Object.keys(action.params).length > 0
                          ? ` ${JSON.stringify(action.params)}`
                          : ''}
                      </Chip>
                    ))}
                  </div>
                </>
              )}

              {(txn.type || inputs.session_id) && (
                <>
                  <h3 className="drawer-h">{t('audit.request')}</h3>
                  <Explainer>{t('audit.request.note')}</Explainer>
                  <div className="table-wrap">
                    <table className="kv">
                      <tbody>
                        {txn.type && <tr><td>{t('drawer.type')}</td><td className="mono">{txn.type}</td></tr>}
                        {txn.amount_bdt !== undefined && (
                          <tr><td>{t('drawer.amount')}</td><td className="mono">{taka(txn.amount_bdt, lang)}</td></tr>
                        )}
                        {txn.to_account && (
                          <tr>
                            <td>{t('drawer.counterparty')}</td>
                            <td>
                              <button className="sm" onClick={() => onOpenAccount(txn.to_account)}>
                                {txn.to_account}
                              </button>
                            </td>
                          </tr>
                        )}
                        {txn.is_new_payee !== undefined && (
                          <tr><td>{t('audit.newpayee')}</td><td className="mono">{String(txn.is_new_payee)}</td></tr>
                        )}
                        {inputs.session_id && (
                          <tr><td>{t('audit.session')}</td><td className="mono">{inputs.session_id}</td></tr>
                        )}
                        {inputs.user_id && <tr><td>{t('audit.user')}</td><td className="mono">{inputs.user_id}</td></tr>}
                      </tbody>
                    </table>
                  </div>
                </>
              )}

              {/* Score rows only carry it: the phone's App Safety report, or the copy risk-mw ignored. */}
              <AppSafetyReport inputs={inputs} />

              {onFlags.length > 0 && (
                <>
                  <h3 className="drawer-h">{t('audit.flags')}</h3>
                  <div className="row">
                    {onFlags.map(([name, value]) => (
                      <Chip key={name} kind={value === true ? 'warn' : tone(String(value).toLowerCase())}>
                        {name}
                        {value === true ? '' : ` ${value}`}
                      </Chip>
                    ))}
                  </div>
                  <Explainer>{t('audit.flags.note')}</Explainer>
                </>
              )}

              {!outputs.decision && Object.keys(outputs).length > 0 && (
                <>
                  <h3 className="drawer-h">{t('audit.response')}</h3>
                  <div className="table-wrap">
                    <table className="kv">
                      <tbody>
                        {Object.entries(outputs)
                          .filter(([, v]) => typeof v !== 'object' || v === null)
                          .map(([key, value]) => (
                            <tr key={key}>
                              <td>{key}</td>
                              <td className="mono">{String(value)}</td>
                            </tr>
                          ))}
                      </tbody>
                    </table>
                  </div>
                </>
              )}

              <div className="toolbar">
                <button className="sm" onClick={() => setShowRaw(!showRaw)}>
                  {showRaw ? t('audit.hideraw') : t('audit.showraw')}
                </button>
                <button
                  className="sm"
                  onClick={() => navigator.clipboard.writeText(JSON.stringify(doc, null, 2))}
                >
                  {t('audit.copy')}
                </button>
              </div>
              {showRaw && (
                <>
                  <Explainer>{t('audit.redacted')}</Explainer>
                  <pre className="trace trace--tall">{JSON.stringify(doc, null, 1)}</pre>
                </>
              )}
            </>
          )}
        </div>
      </aside>
    </>
  )
}
