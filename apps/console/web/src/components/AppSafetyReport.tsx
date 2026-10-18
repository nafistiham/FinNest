/**
 * The App Safety Check result the phone sent with a score, as the audit drawer shows it.
 *
 * risk-mw stores it on the score row as `inputs.app_safety` when the score used it, and as `inputs.app_safety_ignored`
 * ({reason, sent}) when the copy had expired or was a simulated verdict outside demo mode. Like the rest of the drawer
 * this is what was stored: the verdict the phone reported, not the one the rules fused from it (that is the
 * `app_safety_verdict` signal further down). Package names are operator ids, which the console may show.
 */

import { dhakaTime, digits, n } from '../lib/format'
import { label, useT } from '../lib/i18n'
import { Chip, Explainer } from './primitives'
import { Icon } from './Wordmark'

type Doc = Record<string, any>

/* Status by meaning (design system section 3): amber for CAUTION, red for BLOCK only, and the word beside an icon. */
const VERDICT: Record<string, { kind: string; icon: string }> = {
  SAFE: { kind: 'good', icon: 'check_circle' },
  CAUTION: { kind: 'warn', icon: 'warning' },
  BLOCK: { kind: 'bad', icon: 'error' },
}
/* A finding's severity is not a status, so it takes no status colour: the word, with an icon on the two that matter. */
const SEVERITY_ICON: Record<string, string> = { critical: 'error', high: 'warning' }

const isDoc = (value: unknown): value is Doc => typeof value === 'object' && value !== null && !Array.isArray(value)

export function AppSafetyReport({ inputs }: { inputs: Doc }) {
  const { t } = useT()
  const counted = isDoc(inputs.app_safety)
  const ignored = !counted && isDoc(inputs.app_safety_ignored) ? inputs.app_safety_ignored : null
  const report: Doc | null = counted ? inputs.app_safety : ignored && isDoc(ignored.sent) ? ignored.sent : null
  if (!report) return null

  const verdict = String(report.verdict ?? '')
  const mark = VERDICT[verdict] ?? { kind: 'muted', icon: 'info' }
  const findings: Doc[] = Array.isArray(report.findings) ? report.findings.filter(isDoc) : []
  const dropped = Number(report.findings_dropped) || 0
  const reason = String(ignored?.reason ?? '')
  const attestation = typeof report.attestation === 'string' ? report.attestation : ''
  const gloss = attestation ? label(t, 'appsafety.att', attestation) : ''

  return (
    <>
      <h3 className="drawer-h">{t('appsafety.title')}</h3>
      {ignored && (
        <div className="note info">
          <Icon name="info" />
          <div>
            <strong>{t('appsafety.ignored')}</strong>{' '}
            {reason === 'expired' || reason === 'simulated'
              ? t(`appsafety.ignored.${reason}`)
              : t('appsafety.ignored.other', { reason: reason || '—' })}
          </div>
        </div>
      )}
      <div className="row" style={{ marginTop: ignored ? 'var(--fn-space-s)' : 0 }}>
        <Chip kind={mark.kind}>
          <Icon name={mark.icon} />
          {label(t, 'appsafety.verdict', verdict)}
        </Chip>
        {report.simulated_verdict === true && (
          <Chip kind="warn">
            <Icon name="science" />
            {t('appsafety.simulated')}
          </Chip>
        )}
        {typeof report.risk_score === 'number' && (
          <span className="mono">{t('audit.risk')} {digits(String(report.risk_score))}</span>
        )}
      </div>

      <div className="table-wrap" style={{ marginTop: 'var(--fn-space-s)' }}>
        <table className="kv">
          <tbody>
            {report.source && (
              <tr><td>{t('appsafety.source')}</td><td>{label(t, 'appsafety.source', String(report.source))}</td></tr>
            )}
            {attestation && (
              <tr>
                <td>{t('appsafety.attestation')}</td>
                <td>
                  <span className="mono">{attestation}</span>
                  {gloss !== attestation && <> · {gloss}</>}
                </td>
              </tr>
            )}
            {report.checked_at && <tr><td>{t('appsafety.checked')}</td><td className="mono">{dhakaTime(report.checked_at)}</td></tr>}
            {report.valid_until && <tr><td>{t('appsafety.valid')}</td><td className="mono">{dhakaTime(report.valid_until)}</td></tr>}
            {report.check_id && <tr><td>{t('appsafety.check')}</td><td className="mono">{report.check_id}</td></tr>}
          </tbody>
        </table>
      </div>

      <h3 className="drawer-h">{t('appsafety.findings')}</h3>
      {findings.length === 0 ? (
        <div className="dim">{t('appsafety.findings.none')}</div>
      ) : (
        <div className="table-wrap">
          <table className="kv">
            <tbody>
              {findings.map((finding, index) => {
                const severity = String(finding.severity ?? '')
                const icon = SEVERITY_ICON[severity]
                return (
                  <tr key={index}>
                    <td>
                      <Chip kind="muted">
                        {icon && <Icon name={icon} />}
                        {label(t, 'appsafety.severity', severity)}
                      </Chip>
                    </td>
                    <td>
                      <span className="mono">{finding.signal}</span>
                      <div className="dim">
                        {label(t, 'appsafety.scope', String(finding.scope ?? 'app'))}
                        {finding.package ? <> · <span className="mono">{finding.package}</span></> : null}
                      </div>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
      {dropped > 0 && <div className="dim" style={{ marginTop: 'var(--fn-space-s)' }}>{t('appsafety.dropped', { n: n(dropped) })}</div>}
      <Explainer>{t('appsafety.note')}</Explainer>
    </>
  )
}
