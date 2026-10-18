/**
 * The leads at the till or circle in focus, under one candidate filter at a time.
 *
 * Each row is what the run saw (RULE): the cash-out, and the money in and out over the lookback that
 * made the filter name it. The outcome column is the evaluation's, against generated truth, and is
 * badged SYNTHETIC: a candidate is `mule` when it is a labelled non-victim ring member, whenever it is
 * confirmed, exactly as eval/results/cashout.md counts it. Never a verdict, never a block.
 */

import { useState } from 'react'
import { dateOf, stamp } from '../../lib/campaigns'
import { n, taka } from '../../lib/format'
import type { CashoutCandidate, CashoutDayView, CashoutEvalCandidate, CashoutEvaluation, CashoutFilter } from '../../lib/types'
import { Badge, Segmented } from '../primitives'
import { useXT } from './cashoutStrings'

const FILTERS: CashoutFilter[] = ['first_time_senders', 'pass_through']

function Outcome({ row }: { row: CashoutEvalCandidate | undefined }) {
  const xt = useXT()
  if (!row) return <span className="dim">—</span>
  const title = xt('xo.out.title', {
    labelled: row.labelled,
    confirmed: row.confirmed_at ? stamp(row.confirmed_at) : '—',
    lead: row.lead_days === null ? '—' : row.lead_days.toFixed(2),
  })
  return (
    <span className={`chip ${row.outcome === 'mule' ? 't-bad' : 't-muted'}`} title={title}>
      {xt(`xo.out.${row.outcome}`)}
    </span>
  )
}

function Detail({ c }: { c: CashoutCandidate }) {
  const xt = useXT()
  const share = c.pass_through_share
  return (
    <>
      {xt('xo.cand.detail', {
        in: n(c.received_bdt),
        nc: c.new_counterparties,
        out: n(c.cashed_out_bdt),
        share: share === null ? '—' : share.toFixed(2),
        fts: c.first_time_senders,
        first: c.first_day,
      })}
      {share !== null && share > 1.5 && <b className="co-warn-text"> · {xt('xo.cand.drawdown', { x: share.toFixed(1) })}</b>}
    </>
  )
}

/** True candidates the analysts confirm after the world's last daily run: counted true, with their lead. */
function lateConfirmed(evaluation: CashoutEvaluation | null, lastAsOf: string | null): CashoutEvalCandidate[] {
  if (!evaluation || !lastAsOf) return []
  return evaluation.candidates.filter((r) => r.outcome === 'mule' && r.confirmed_at !== null && r.confirmed_at > lastAsOf)
}

export function CashoutCandidates({
  day,
  tills,
  evaluation,
  lastAsOf,
}: {
  day: CashoutDayView
  tills: string[]
  evaluation: CashoutEvaluation | null
  lastAsOf: string | null
}) {
  const xt = useXT()
  const [filter, setFilter] = useState<CashoutFilter>('pass_through')
  const here = day.candidates.filter((c) => tills.includes(c.till))
  const rows = here.filter((c) => c.filter === filter)
  const outcomes = new Map((evaluation?.candidates ?? []).map((r) => [`${r.acct}|${r.filter}`, r]))
  const late = lateConfirmed(evaluation, lastAsOf)
  const held = day.not_flagged[filter] ?? 0

  return (
    <div className="co-cands">
      <div className="co-row">
        <h3 className="co-h3">{xt('xo.filter')}</h3>
        <Segmented
          value={filter}
          onChange={setFilter}
          label={xt('xo.filter')}
          options={FILTERS.map((f) => ({ value: f, label: `${xt(`xo.filter.${f}`)} · ${here.filter((c) => c.filter === f).length}` }))}
        />
      </div>
      <div className="table-wrap co-table">
        <table>
          <thead>
            <tr>
              <th>{xt('xo.col.acct')}</th>
              <th>{xt('xo.col.time')}</th>
              <th className="num">{xt('xo.col.amount')}</th>
              <th>
                {xt('xo.col.outcome')} <Badge kind="SYNTHETIC" />
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 && (
              <tr>
                <td colSpan={4} className="dim">
                  {xt('xo.cand.none')}
                </td>
              </tr>
            )}
            {rows.flatMap((c) => [
              <tr key={`${c.acct}|${c.filter}`} className="co-row-cand">
                <td className="mono">{c.acct}</td>
                <td className="mono" title={stamp(c.ts)}>
                  {dateOf(c.ts).slice(5)} {stamp(c.ts).slice(11, 16)}
                </td>
                <td className="num">{taka(c.amount_bdt)}</td>
                <td>
                  <Outcome row={outcomes.get(`${c.acct}|${c.filter}`)} />
                </td>
              </tr>,
              <tr key={`${c.acct}|${c.filter}|detail`} className="co-row-cand co-detail">
                <td colSpan={4}>
                  {c.till} · <Detail c={c} />
                </td>
              </tr>,
            ])}
          </tbody>
        </table>
      </div>
      <p className="co-sub">{xt('xo.heldback', { n: held })}</p>
      <p className="co-sub">{xt('xo.filter.note')}</p>
      {late.length > 0 && lastAsOf && (
        <p className="co-sub co-late">
          <Badge kind="SYNTHETIC" />{' '}
          {xt('xo.late', {
            n: late.length,
            accts: [...new Set(late.map((r) => r.acct))].join(', '),
            date: [...new Set(late.map((r) => dateOf(r.confirmed_at ?? '')))].join(', '),
            last: stamp(lastAsOf),
          })}
        </p>
      )}
    </div>
  )
}
