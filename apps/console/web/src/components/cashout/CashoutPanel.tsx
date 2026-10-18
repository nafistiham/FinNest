/**
 * The incident beside the map: for a flagged till, its seed accounts, observed against
 * expected and the Poisson tail; for a replayed cluster, the same for the circle, labelled REPLAY
 * with what that means in one line. Then the evaluation's sentence (SYNTHETIC), the candidates under
 * either filter, and the next steps, every one of them off until the case actions are wired.
 *
 * Provenance on every figure: the flag and the cluster are RULE output; outcomes and the evaluation
 * line are SYNTHETIC, measured against generated truth.
 */

import { dateOf, fmtCount, hm, stamp } from '../../lib/campaigns'
import { taka } from '../../lib/format'
import type { CashoutCluster, CashoutDayView, CashoutEvaluation, CashoutTillFlag } from '../../lib/types'
import { Badge, Tile } from '../primitives'
import { CashoutCandidates } from './CashoutCandidates'
import type { Resolved } from './cashoutMath'
import { configNumber, memberRole, oneIn } from './cashoutMath'
import { useXT } from './cashoutStrings'

type XT = ReturnType<typeof useXT>

function Unusual({ p, threshold, xt }: { p: number; threshold: number; xt: XT }) {
  const shown = oneIn(p)
  const value = shown.kind === 'below' ? xt('xo.p.below') : shown.kind === 'onein' ? xt('xo.p.onein', { n: shown.n }) : shown.n
  return (
    <Tile
      label={xt('xo.unusual')}
      value={<span title={shown.exact}>{value}</span>}
      sub={xt('xo.unusual.sub', { p: threshold.toExponential(0) })}
      badge="RULE"
      small
    />
  )
}

function EvalLine({ evaluation, cluster, xt }: { evaluation: CashoutEvaluation | null; cluster: boolean; xt: XT }) {
  const measures = evaluation?.measures
  const flags = measures?.till_flags
  const text = !measures
    ? xt('xo.eval.none')
    : cluster
      ? xt('xo.eval.clusters', {
          n: measures.replayed_clusters?.clusters ?? '—',
          events: measures.replayed_clusters?.events ?? '—',
          live: measures.live_clusters ?? '—',
          lag: configNumber(evaluation?.config, 'CONFIRMATION_LAG_DAYS', Number.NaN),
        })
      : flags
        ? xt('xo.eval.flags', {
            h: configNumber(evaluation?.config, 'HORIZON_DAYS', Number.NaN),
            right: flags.right,
            scored: flags.scored_till_days,
            base: flags.base_rate === null ? '—' : flags.base_rate.toFixed(2),
          })
        : xt('xo.eval.none')
  return (
    <p className="co-eval">
      <Badge kind={measures ? 'SYNTHETIC' : 'NO DATA'} /> {text}
    </p>
  )
}

function FlagFacts({ flag, day, config, xt }: { flag: CashoutTillFlag; day: CashoutDayView; config: Record<string, unknown>; xt: XT }) {
  const days = configNumber(config, 'TILL_REUSE_DAYS', 30)
  const here = day.candidates.filter((c) => c.till === flag.id)
  return (
    <>
      <div className="co-status">
        <span className="co-dot-status" />
        <div>
          <strong>
            {xt('xo.flag.title', { id: flag.id })} <Badge kind="RULE" />
          </strong>
          <span className="co-sub">{xt('xo.flag.sub', { n: flag.seed_accounts.length, days })}</span>
        </div>
      </div>
      <div className="co-tiles">
        <Tile label={xt('xo.seeds')} value={flag.seed_accounts.length} sub={xt('xo.seeds.sub', { days })} badge="RULE" />
        <Tile label={xt('xo.expected')} value={fmtCount(flag.expected)} sub={xt('xo.expected.sub', { n: flag.accounts })} badge="RULE" />
        <Unusual p={flag.p_value} threshold={configNumber(config, 'TILL_REUSE_P_THRESHOLD', 0.001)} xt={xt} />
        <Tile label={xt('xo.cands')} value={new Set(here.map((c) => c.acct)).size} sub={xt('xo.cands.sub')} badge="RULE" />
      </div>
      <dl className="co-kv">
        <div>
          <dt>{xt('xo.firstseen')}</dt>
          <dd className="mono">{stamp(flag.first_seen_ts)}</dd>
        </div>
        <div>
          <dt>{xt('xo.lastseed')}</dt>
          <dd className="mono">{stamp(flag.last_seed_ts)}</dd>
        </div>
        <div className="co-full">
          <dt>{xt('xo.seedlist')}</dt>
          <dd className="co-accts">
            {flag.seed_accounts.map((acct) => (
              <span key={acct} className="co-acct">
                {acct}
              </span>
            ))}
          </dd>
        </div>
      </dl>
    </>
  )
}

function ClusterFacts({
  cluster,
  day,
  seeds,
  config,
  xt,
}: {
  cluster: CashoutCluster
  day: CashoutDayView
  seeds: Set<string>
  config: Record<string, unknown>
  xt: XT
}) {
  const candidates = new Set(day.candidates.map((c) => c.acct))
  const members = [...cluster.seed_cashouts, ...cluster.other_cashouts]
    .map((p) => ({ ...p, role: memberRole(cluster, p.acct, seeds, candidates) }))
    .sort((a, b) => a.ts.localeCompare(b.ts) || a.txn_id.localeCompare(b.txn_id))
  const seeded = new Set(members.filter((m) => m.role === 'seed').map((m) => m.acct))
  return (
    <>
      <div className="co-status">
        <span className="co-dot-status" />
        <div>
          <strong>
            {xt('xo.cluster.title', { id: cluster.cluster_id })}{' '}
            <span className="badge t-warn">{cluster.mode === 'replay' ? 'REPLAY' : 'LIVE'}</span> <Badge kind="RULE" />
          </strong>
          <span className="co-sub">{xt(cluster.mode === 'replay' ? 'xo.replay.line' : 'xo.live.line')}</span>
        </div>
      </div>
      <div className="co-tiles">
        <Tile
          label={xt('xo.cluster.seeds')}
          value={seeded.size}
          sub={xt('xo.cluster.seeds.sub', { min: configNumber(config, 'CLUSTER_MIN_SEEDS', 3) })}
          badge="RULE"
        />
        <Tile label={xt('xo.cluster.obs')} value={cluster.observed} sub={xt('xo.cluster.obs.sub', { e: fmtCount(cluster.expected) })} badge="RULE" />
        <Unusual p={cluster.p_value} threshold={configNumber(config, 'CLUSTER_P_THRESHOLD', 1e-7)} xt={xt} />
        <Tile
          label={xt('xo.cluster.window')}
          value={`${hm(cluster.window_start)}–${hm(cluster.window_end)}`}
          sub={`${dateOf(cluster.window_start)} · ${xt('xo.cluster.where', { km: cluster.radius_km, tills: cluster.tills.join(', ') })}`}
          badge="RULE"
          small
        />
      </div>
      <h3 className="co-h3">{xt('xo.members')}</h3>
      <div className="table-wrap co-table">
        <table>
          <tbody>
            {members.map((m) => (
              <tr key={m.txn_id} className={`co-row-${m.role}`}>
                <td className="mono">{m.acct}</td>
                <td className="mono">{m.till}</td>
                <td className="mono">{hm(m.ts)}</td>
                <td className="num">{taka(m.amount_bdt)}</td>
                <td className="dim">{xt(`xo.member.${m.role}`)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  )
}

function Actions({ xt }: { xt: XT }) {
  return (
    <div className="co-actions">
      <h3 className="co-h3">{xt('xo.actions')}</h3>
      {(['xo.act.casezero', 'xo.act.review', 'xo.act.watch'] as const).map((key) => (
        <div className="co-action" key={key}>
          <button type="button" disabled title={xt('xo.notwired')}>
            {xt(key)}
          </button>
          <span className="chip t-warn">{xt('xo.notwired')}</span>
        </div>
      ))}
      <p className="co-sub">{xt('xo.never')}</p>
    </div>
  )
}

export function CashoutPanel({
  day,
  focus,
  seeds,
  evaluation,
  config,
  lastAsOf,
}: {
  day: CashoutDayView
  focus: Resolved
  /** Confirmed mules as of the run: a circle's members are drawn and counted against these. */
  seeds: Set<string>
  evaluation: CashoutEvaluation | null
  config: Record<string, unknown>
  lastAsOf: string | null
}) {
  const xt = useXT()
  return (
    <>
      {focus.flag && <FlagFacts flag={focus.flag} day={day} config={config} xt={xt} />}
      {focus.cluster && <ClusterFacts cluster={focus.cluster} day={day} seeds={seeds} config={config} xt={xt} />}
      <EvalLine evaluation={evaluation} cluster={focus.cluster !== null} xt={xt} />
      <CashoutCandidates day={day} tills={focus.tills} evaluation={evaluation} lastAsOf={lastAsOf} />
      <Actions xt={xt} />
    </>
  )
}
