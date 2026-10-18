/**
 * Gemini's reading of one stored score, in the audit drawer.
 *
 * The drawer's reasons are what the customer was told, word for word, and they stay below this as the record.
 * This section is for the operator: which reason set the score, which asked for the decision, which signals were set
 * from the demo panel, and what to check next. The service checks every code and number Gemini writes against the
 * row before it gets here (api/insight.py), so this only renders; it never decides.
 *
 * Gemini's text is shown in the active language only and marked with its `lang`, so the right font and voice apply.
 */

import type { AuditInsight } from '../lib/types'
import { digits } from '../lib/format'
import { useT } from '../lib/i18n'
import { Chip, Explainer } from './primitives'
import { Icon } from './Wordmark'

export type InsightState =
  | { status: 'loading' }
  | { status: 'failed'; message: string }
  | { status: 'done'; answer: AuditInsight }

/* Trying again can help only where the model was slow or briefly unavailable; off, spent or wrong stays so. */
const RETRYABLE = new Set(['timeout', 'genai_error'])

export function GeminiInsight({ state, onRetry }: { state: InsightState; onRetry: () => void }) {
  const { t, lang } = useT()
  const say = (en: string, bn: string) => (lang === 'bn' ? bn : en)
  const retry = (
    <button className="sm" onClick={onRetry}>
      <Icon name="refresh" />
      {t('insight.retry')}
    </button>
  )

  let body
  if (state.status === 'loading') {
    body = (
      <div className="skeleton" aria-busy="true">
        <div className="skel-line" style={{ width: '90%' }} />
        <div className="skel-line" style={{ width: '70%' }} />
        <div className="dim">{t('insight.loading')}</div>
      </div>
    )
  } else if (state.status === 'failed') {
    body = (
      <div className="note info">
        <Icon name="info" />
        <div>
          {t('insight.failed')} <span className="mono">{state.message}</span>
          <div style={{ marginTop: 'var(--fn-space-s)' }}>{retry}</div>
        </div>
      </div>
    )
  } else if (!state.answer.available || !state.answer.insight) {
    const reason = state.answer.reason ?? ''
    const key = `insight.off.${reason}`
    const worded = t(key) === key ? t('insight.off.other', { reason: reason || '—' }) : t(key)
    body = (
      <div className="note info">
        <Icon name="info" />
        <div>
          {worded}
          {RETRYABLE.has(reason) && <div style={{ marginTop: 'var(--fn-space-s)' }}>{retry}</div>}
        </div>
      </div>
    )
  } else {
    const { insight, model_id, cached, latency_ms } = state.answer
    body = (
      <>
        <p lang={lang}>{say(insight.summary_en, insight.summary_bn)}</p>
        {insight.drivers.map((driver) => (
          <div className="tile" key={driver.code} style={{ marginBottom: 8 }}>
            <div className="row">
              <Chip kind="muted">{driver.code}</Chip>
              {driver.weight !== null && <span className="mono dim">{t('audit.weight')} {digits(String(driver.weight))}</span>}
            </div>
            <div lang={lang}>{say(driver.reading_en, driver.reading_bn)}</div>
          </div>
        ))}
        {insight.next_checks.length > 0 && (
          <>
            <h4 className="drawer-h">{t('insight.checks')}</h4>
            <ul lang={lang}>
              {insight.next_checks.map((check, index) => (
                <li key={index}>{say(check.en, check.bn)}</li>
              ))}
            </ul>
          </>
        )}
        <div className="note info">
          <Icon name="info" />
          <div lang={lang}>{say(insight.caveat_en, insight.caveat_bn)}</div>
        </div>
        <div className="dim" style={{ marginTop: 'var(--fn-space-s)' }}>
          <span className="mono">{model_id ?? '—'}</span> ·{' '}
          {cached ? t('insight.cached') : t('insight.fresh', { s: digits(((latency_ms ?? 0) / 1000).toFixed(1)) })}
        </div>
      </>
    )
  }

  return (
    <>
      <h3 className="drawer-h">{t('insight.title')}</h3>
      {/* The reading arrives seconds after the drawer opens; a polite live region lets a screen reader hear it land. */}
      <div aria-live="polite">{body}</div>
      <Explainer>{t('insight.note')}</Explainer>
    </>
  )
}
