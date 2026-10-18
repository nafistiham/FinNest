/**
 * The campaign as the radar linked it.
 *
 * Four columns: senders, payees, the entities that join payees, and the payees' known next hops.
 * Every solid entity edge comes from `Campaign.evidence` and nothing else: a triple
 * [attempt, linked attempt, entity] joins the payees of both attempts to that entity, and hovering the
 * edge lists its triples. Shared entities the payees hold as of the campaign that no triple needed are
 * drawn dashed amber and say so; next hops are dotted context. A sender-to-payee line is an attempted
 * payment, holds included, not a transfer. Clicking an evidence entity lights the payments its
 * triples name.
 */

import { useEffect, useState, type KeyboardEvent } from 'react'
import type { CampaignAttempt, RadarCampaign } from '../../lib/campaigns'
import { byTime, linkingEntities } from '../../lib/campaigns'
import { useCT } from '../../lib/campaignStrings'

const COL = { sender: 40, payee: 255, entity: 520, hop: 790 }
const SENDER_GAP = 9
const clip = (text: string, max = 24) => (text.length > max ? `${text.slice(0, max - 1)}…` : text)

/** Evenly down the column, or centred when there is one. */
const spread = (count: number, top: number, bottom: number) => (i: number) =>
  count <= 1 ? (top + bottom) / 2 : top + (i * (bottom - top)) / (count - 1)

export function EvidenceGraph({ campaign, attempts }: { campaign: RadarCampaign; attempts: Map<string, CampaignAttempt> }) {
  const ct = useCT()
  const [picked, setPicked] = useState<string | null>(null)
  useEffect(() => setPicked(null), [campaign.campaign_id])

  const payees = campaign.payees
  const own = campaign.attempt_ids
    .map((id) => attempts.get(id))
    .filter((a): a is CampaignAttempt => Boolean(a))
    .sort((a, b) => payees.indexOf(a.payee ?? '') - payees.indexOf(b.payee ?? '') || byTime(a, b))
  const payeeOf = new Map([...attempts.values()].map((a) => [a.attempt_id, a.payee]))
  const entities = linkingEntities(campaign, payeeOf)
  const senders = [...new Set(own.map((a) => a.sender))]
  const hopsOf = new Map(payees.map((p) => [p, [...new Set(own.filter((a) => a.payee === p).flatMap((a) => a.payee_next_hops))].sort()]))
  const hops = [...new Set([...hopsOf.values()].flat())].filter((h) => !payees.includes(h)).sort()

  const height = Math.max(340, 56 + senders.length * SENDER_GAP, 80 + payees.length * 52, 80 + entities.length * 44)
  const at = new Map<string, { x: number; y: number }>()
  senders.forEach((s, i) => at.set(s, { x: COL.sender, y: 40 + i * SENDER_GAP }))
  const payeeY = spread(payees.length, 50, height - 40)
  payees.forEach((p, i) => at.set(p, { x: COL.payee, y: payeeY(i) }))
  const entityY = spread(entities.length, 50, height - 60)
  entities.forEach((e, i) => at.set(e.entity, { x: COL.entity, y: entityY(i) }))
  const hopY = spread(hops.length, height / 2, height - 40)
  hops.forEach((h, i) => at.set(h, { x: COL.hop, y: hopY(i) }))

  const lit = new Set(entities.find((e) => e.entity === picked)?.triples.flat() ?? [])
  const toggle = (entity: string) => setPicked(picked === entity ? null : entity)
  const onKey = (entity: string) => (event: KeyboardEvent) => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault()
      toggle(entity)
    }
  }
  const line = (a: string, b: string, className: string, title?: string, key?: string) => {
    const p = at.get(a)
    const q = at.get(b)
    if (!p || !q) return null
    return (
      <line key={key ?? `${a}>${b}`} className={className} x1={p.x} y1={p.y} x2={q.x} y2={q.y}>
        {title && <title>{title}</title>}
      </line>
    )
  }

  return (
    <svg className="cv-svg" viewBox={`0 0 900 ${height}`} role="img" aria-label={`${ct('cv.graph')} ${campaign.campaign_id}`}>
      <text x={10} y={18}>{senders.length} · {ct('cv.sender')}</text>
      <text x={COL.payee - 40} y={18}>{payees.length} · {ct('cv.payee')}</text>
      <text x={COL.entity - 40} y={18}>{ct('cv.linking')}</text>
      {hops.length > 0 && <text x={COL.hop - 40} y={height / 2 - 24}>{ct('cv.nexthop')}</text>}

      {own.map((a) =>
        a.payee ? line(a.sender, a.payee, lit.has(a.attempt_id) ? 'cv-edge cv-lit' : 'cv-edge', undefined, a.attempt_id) : null,
      )}
      {entities.flatMap((e) =>
        e.payees.map((p) =>
          line(
            p,
            e.entity,
            e.inEvidence ? 'cv-evidence' : 'cv-shared',
            e.inEvidence
              ? `${e.entity} · ${e.triples.length} evidence triples: ${e.triples.map(([s, d]) => `${d} ← ${s}`).join(', ')}`
              : `${e.entity} · ${ct('cv.shared')} · ${ct('cv.asof')} ${campaign.as_of}`,
          ),
        ),
      )}
      {payees.flatMap((p) => (hopsOf.get(p) ?? []).map((h) => line(p, h, 'cv-hop', `${p} → ${h} · ${ct('cv.nexthop')}`)))}

      {senders.map((s) => {
        const { x, y } = at.get(s)!
        return (
          <circle key={s} className="cv-sender" cx={x} cy={y} r={3}>
            <title>{s}</title>
          </circle>
        )
      })}
      {payees.map((p) => {
        const { x, y } = at.get(p)!
        return (
          <g key={p}>
            <rect className="cv-node" x={x - 42} y={y - 14} width={84} height={28} rx={5} />
            <text className="cv-label" x={x} y={y + 4} textAnchor="middle">{p}</text>
          </g>
        )
      })}
      {entities.map((e) => {
        const { x, y } = at.get(e.entity)!
        const className = `cv-node${e.inEvidence ? '' : ' cv-context'}${picked === e.entity ? ' cv-picked' : ''}`
        const interactive = e.inEvidence && e.triples.length > 0
        return (
          <g
            key={e.entity}
            className={interactive ? 'cv-clickable' : undefined}
            tabIndex={interactive ? 0 : undefined}
            role={interactive ? 'button' : undefined}
            aria-pressed={interactive ? picked === e.entity : undefined}
            onClick={interactive ? () => toggle(e.entity) : undefined}
            onKeyDown={interactive ? onKey(e.entity) : undefined}
          >
            <title>{`${e.entity}${e.inEvidence ? ` · ${e.triples.length} triples` : ` · ${ct('cv.shared')}`}`}</title>
            <circle className={className} cx={x} cy={y} r={12} />
            <text className="cv-label" x={x + 18} y={y + 1}>{clip(e.value)}</text>
            <text className="cv-caption" x={x + 18} y={y + 14}>
              {ct(`cv.kind.${e.kind}`)}
              {e.inEvidence ? '' : ` · ${ct('cv.shared')}`}
            </text>
          </g>
        )
      })}
      {hops.map((h) => {
        const { x, y } = at.get(h)!
        return (
          <g key={h}>
            <circle className="cv-hopnode" cx={x} cy={y} r={6} />
            <text x={x + 12} y={y + 4}>{h}</text>
          </g>
        )
      })}
    </svg>
  )
}
