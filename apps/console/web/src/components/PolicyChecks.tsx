/**
 * The team's own rules, checked against what the engine actually did.
 *
 * `block = 0` is otherwise an empty bar nobody reads. Stated as a policy and checked, it becomes
 * evidence that no model took a decision only an analyst may take. One of these three fails today,
 * and it stays on the screen failing until somebody builds a release path.
 */

import type { PolicyCheck } from '../lib/types'
import { Panel } from './primitives'
import { useT } from '../lib/i18n'
import { n } from '../lib/format'
import { Icon } from './Wordmark'

export function PolicyChecks({ policy }: { policy: PolicyCheck[] }) {
  const { t, pick } = useT()
  const failing = policy.filter((check) => !check.ok).length
  return (
    <Panel
      title={t('policy.title')}
      question={t('policy.q')}
      info="policy"
      right={
        <span className={`chip ${failing ? 't-bad' : 't-good'}`}>
          <Icon name={failing ? 'error' : 'check_circle'} />
          {n(policy.length - failing)} / {n(policy.length)} {t('policy.ofholding')}
        </span>
      }
    >
      <div className="grid" style={{ gap: 8 }}>
        {policy.map((check) => (
          <div key={check.id} className={`note flush ${check.ok ? 'good' : 'bad'}`}>
            <Icon name={check.ok ? 'check_circle' : 'error'} />
            <div>
            <div className="row">
              <span className={`chip ${check.ok ? 't-good' : 't-bad'}`}>
                {check.ok ? t('policy.holding') : t('policy.notyet')}
              </span>
              <b>{pick(check, 'statement')}</b>
            </div>
            <div>{pick(check, 'evidence')}</div>
            <div className="mono dim">{check.source}</div>
            </div>
          </div>
        ))}
      </div>
    </Panel>
  )
}
