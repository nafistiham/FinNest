/**
 * One row per model, read from the eval files the eval harnesses write.
 *
 * Nothing here is typed in by hand, and a failed gate is reported as failed: case-zero misses its
 * latency-and-cost gate and this table says so. A model-health page that only shows passes is
 * decoration - and one that reports a met gate as missed is worse, because it teaches the operator
 * to stop believing the column. A model with no gate verdict at all shows a dash, not a cross.
 */

import type { ModelRow } from '../lib/types'
import { Badge, Panel } from './primitives'
import { useT } from '../lib/i18n'
import { digits } from '../lib/format'
import { Icon } from './Wordmark'

export function ModelHealth({ models }: { models: ModelRow[] }) {
  const { t } = useT()
  return (
    <Panel title={t('models.title')} question={t('models.q')}>
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>{t('models.model')}</th>
              <th>{t('models.version')}</th>
              <th>{t('models.headline')}</th>
              <th>{t('models.gates')}</th>
              <th>{t('models.eval')}</th>
            </tr>
          </thead>
          <tbody>
            {models.map((model) => (
              <tr key={model.id}>
                <td>
                  <b>{model.id}</b> <Badge kind={model.badge} />
                  {model.note && (
                    <div className="dim">{model.note}</div>
                  )}
                  {model.per_segment && (
                    <div className="model-segments">
                      <span className="dim">{model.per_segment_label}</span>
                      {Object.entries(model.per_segment)
                        .sort((a, b) => a[1] - b[1])
                        .map(([name, value]) => (
                          <div key={name} className={`mono ${value < 0.5 ? 't-text-bad' : 'dim'}`}>
                            {value < 0.5 && <Icon name="warning" />}
                            {name} {digits(String(value))}
                          </div>
                        ))}
                    </div>
                  )}
                </td>
                <td className="mono dim">{model.version ?? '—'}</td>
                <td>{model.headline ?? '—'}</td>
                <td>
                  {model.gates_passed === null || model.gates_passed === undefined ? (
                    <span className="dim">—</span>
                  ) : model.gates_passed ? (
                    <span className="chip t-good"><Icon name="check_circle" />{t('models.passed')}</span>
                  ) : (
                    <span className="chip t-bad"><Icon name="error" />{t('models.missed')}</span>
                  )}
                  {model.gates_detail && (
                    <div className="mono model-gates">
                      {Object.entries(model.gates_detail).map(([gate, ok]) => (
                        <div key={gate} className={ok ? 'dim' : 't-text-bad'}>
                          {ok ? '✓' : '✗'} {gate}
                        </div>
                      ))}
                    </div>
                  )}
                  {model.cost_usd !== undefined && model.cost_usd !== null && (
                    <div className="mono dim">
                      {t('models.cost')} ${digits(String(model.cost_usd))}
                    </div>
                  )}
                </td>
                <td className="mono dim">{model.eval ?? '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </Panel>
  )
}
