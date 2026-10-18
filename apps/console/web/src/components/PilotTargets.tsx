/**
 * The five targets the team set itself, including the four nothing can measure yet.
 *
 * Showing a target as NO DATA is the point. Three of these need a release path that does not exist,
 * and a target nobody can see is a target nobody hits.
 */

import type { Target } from '../lib/types'
import { n } from '../lib/format'
import { Panel, Tile, Explainer } from './primitives'
import { useT } from '../lib/i18n'

export function PilotTargets({ targets }: { targets: Target[] }) {
  const { t, pick } = useT()
  const measured = targets.filter((target) => target.value !== null).length
  return (
    <Panel
      title={t('targets.title')}
      question={t('targets.q')}
      info="targets"
      right={
        <span className="chip t-muted">
          {n(measured)} / {n(targets.length)} {t('targets.measurable')}
        </span>
      }
    >
      <div className="grid g-4">
        {targets.map((target) => (
          <Tile
            key={target.id}
            label={pick(target, 'label')}
            badge={target.badge}
            small={target.value === null}
            value={
              target.value === null ? (
                <span className="dim">{pick(target, 'target')}</span>
              ) : (
                `${target.unit === 'BDT' ? '৳ ' : ''}${n(target.value)}`
              )
            }
            sub={target.value === null ? pick(target, 'why') : `${t('targets.target')}: ${pick(target, 'target')}`}
          />
        ))}
      </div>
      <Explainer>
        <code>defence-in-depth plan</code> §5
      </Explainer>
    </Panel>
  )
}
