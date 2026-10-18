/**
 * The live half: risk-mw as it is answering right now.
 *
 * Everything in here is a click. risk-mw's Gemini routes allow 30 calls a minute per caller behind
 * a five-dollar spend ledger, and an investigation holds one of eighty concurrent slots for about a
 * minute, so a console that polled them would burn the team's budget during judging. Health is the
 * only thing on a timer, and it is slow.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import type { MuleScore, RiskMwHealth, TraceEvent } from '../lib/types'
import { ApiError, demoRing, investigate, muleScore, riskMwBase, riskMwHealth, setRiskMwBase, streamCase } from '../lib/api'
import { digits, fx, n } from '../lib/format'
import { Icon } from './Wordmark'
import { Chip, Panel, Explainer } from './primitives'
import { useT } from '../lib/i18n'

const HEALTH_INTERVAL_MS = 30_000

export function LivePanel({ onOpenAccount }: { onOpenAccount: (acctId: string) => void }) {
  const { t } = useT()
  const [health, setHealth] = useState<RiskMwHealth | null>(null)
  const [healthError, setHealthError] = useState<string | null>(null)
  const [ring, setRing] = useState<Record<string, string[]>>({})
  const [selected, setSelected] = useState<string | null>(null)
  const [score, setScore] = useState<MuleScore | null>(null)
  const [trace, setTrace] = useState<TraceEvent[]>([])
  const [caseId, setCaseId] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [base, setBase] = useState(riskMwBase())
  const abortRef = useRef<(() => void) | null>(null)

  const ping = useCallback(async () => {
    try {
      setHealth(await riskMwHealth())
      setHealthError(null)
    } catch (err) {
      setHealthError((err as Error).message)
    }
  }, [])

  useEffect(() => {
    void ping()
    const timer = setInterval(() => void ping(), HEALTH_INTERVAL_MS)
    return () => clearInterval(timer)
  }, [ping])

  useEffect(() => {
    demoRing().then(setRing).catch(() => setRing({}))
  }, [])

  useEffect(() => () => abortRef.current?.(), [])

  const pick = async (acctId: string) => {
    setSelected(acctId)
    setScore(null)
    setError(null)
    try {
      setScore(await muleScore(acctId))
    } catch (err) {
      setError(err instanceof ApiError && err.status === 429 ? err.message : (err as Error).message)
    }
  }

  const openCase = async () => {
    if (!selected) return
    setBusy(true)
    setError(null)
    setTrace([])
    try {
      const { case_id } = await investigate(selected)
      setCaseId(case_id)
      abortRef.current?.()
      abortRef.current = streamCase(
        case_id,
        (event) => setTrace((events) => [...events, event]),
        (streamError) => {
          setBusy(false)
          if (streamError) setError(streamError)
        },
      )
    } catch (err) {
      setBusy(false)
      setError(err instanceof ApiError && err.status === 429 ? err.message : (err as Error).message)
    }
  }

  const stop = () => {
    abortRef.current?.()
    setBusy(false)
  }

  return (
    <Panel
      title={t('live.title')}
      question={t('live.q')}
      info="live"
      right={
        health ? (
          <Chip kind="good">
            <Icon name="check_circle" />
            {health.service} · {health.model_version} · demo_mode={String(health.demo_mode)}
          </Chip>
        ) : (
          <Chip kind={healthError ? 'bad' : 'muted'}>
            {healthError && <Icon name="error" />}
            {healthError ?? t('live.checking')}
          </Chip>
        )
      }
    >
      <label className="row field-inline">
        <span className="dim">risk-mw</span>
        <input
          className="grow"
          value={base}
          onChange={(event) => setBase(event.target.value)}
          onBlur={() => {
            setRiskMwBase(base)
            void ping()
          }}
        />
      </label>

      <div className="row gap-top">
        {Object.entries(ring).map(([role, accounts]) =>
          accounts.map((acct) => (
            <button key={acct} className={`sm${selected === acct ? ' on' : ''}`} onClick={() => void pick(acct)}>
              {acct} <span className="dim">{role}</span>
            </button>
          )),
        )}
        {Object.keys(ring).length === 0 && <span className="dim">{t('live.ring_missing')}</span>}
      </div>

      {score && (
        <div className="tile gap-top">
          <div className="row">
            <b className="mono">{score.acct_id}</b>
            <Chip kind={score.probability >= 0.8 ? 'bad' : 'warn'}>p(mule) {fx(score.probability, 4)}</Chip>
            <Chip kind={score.known ? 'good' : 'muted'}>{score.known ? t('live.known') : t('live.unknown')}</Chip>
            <span className="chip t-muted">{score.model_version}</span>
            <span className="spacer" />
            <button className="sm" onClick={() => onOpenAccount(score.acct_id)}>
              {t('live.open_account')}
            </button>
            <button className="sm primary" onClick={() => void openCase()} disabled={busy}>
              {busy ? t('live.investigating') : t('live.open_case')}
            </button>
            {busy && (
              <button className="sm" onClick={stop}>
                {t('live.stop')}
              </button>
            )}
          </div>
          <div className="gap-top">
            {score.reasons.slice(0, 3).map((reason) => (
              <div key={reason.feature} className="mono dim">
                {reason.direction === 'up' ? '▲' : '▼'} {reason.feature} {reason.contribution > 0 ? '+' : reason.contribution < 0 ? '−' : ''}
                {digits(String(Math.abs(reason.contribution)))}
              </div>
            ))}
          </div>
        </div>
      )}

      {error && (
        <div className="note bad" role="alert">
          <Icon name="error" />
          <div>
            {error}
            <div>{t('error.next')}</div>
          </div>
        </div>
      )}

      {caseId && (
        <div className="gap-top">
          <div className="row">
            <span className="chip t-violet">{caseId}</span>
            <span className="dim">
              {n(trace.length)} {t('live.events')}
            </span>
          </div>
          <div className="trace">
            {trace.map((event, index) => (
              <div key={index} className="step">
                <span className="k">{event.step}</span>{' '}
                {event.step === 'tool'
                  ? `${event.name} ${JSON.stringify(event.args ?? {})}`
                  : event.step === 'evidence'
                    ? `${event.row_id} — ${event.text}`
                    : event.step === 'done'
                      ? `${t('live.confidence')} ${digits(String(event.confidence))}`
                      : (event.text ?? '')}
              </div>
            ))}
            {trace.length === 0 && <div className="dim">{t('live.waiting')}</div>}
          </div>
        </div>
      )}

      <Explainer>{t('live.note')}</Explainer>
    </Panel>
  )
}
