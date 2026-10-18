/**
 * The system as a graph: seven things, the arrows between them, and one payment's path.
 *
 * The first attempt at this page was boxes of prose, and it read like documentation nobody asked
 * for. A reader wants the shape first - what talks to what - and the sentence only for the one
 * box they are looking at. So the sentences are one line each and live behind a click.
 *
 * Positions are fixed rather than simulated: seven nodes in three rows is a picture someone can
 * learn, and a force layout would redraw it differently every visit.
 */

import { useEffect, useState } from 'react'
import { getArchitecture, getScenarios } from '../../lib/api'
import type { Architecture, Scenario } from '../../lib/types'
import { stepsFor, type Step } from '../../lib/play'
import { useT } from '../../lib/i18n'
import { n } from '../../lib/format'
import { Badge, Chip, Panel } from '../primitives'
import { outcomeMark } from '../../lib/events'
import { DatabaseShape, FilesShape, PhoneShape, ScreenShape, SparkShape } from '../SysShapes'

/* viewBox units.
 *
 * The two services are containers, not boxes: the models run *inside* them, so they are drawn
 * inside them. That is the whole point of the picture - "the payee scorer is part of the decision
 * service" is a fact about the system, and a separate panel of cards said it far worse than one
 * rectangle inside another.
 *
 * Positions are fixed, not simulated, and chosen so no arrow crosses another.
 */
const W = 1180
const H = 470

interface Box { x: number; y: number; w: number; h: number }

/* The console moved to sit beside the two things it reads. It used to be bottom-left, which meant
   both its arrows had to cross the service to get anywhere. */
const NODE: Record<string, Box> = {
  app: { x: 14, y: 40, w: 112, h: 72 },
  ledger: { x: 14, y: 206, w: 112, h: 60 },
  'risk-mw': { x: 176, y: 10, w: 448, h: 318 },
  artefacts: { x: 676, y: 16, w: 132, h: 56 },
  gemini: { x: 676, y: 96, w: 132, h: 56 },
  trusted: { x: 676, y: 176, w: 132, h: 56 },
  firestore: { x: 676, y: 256, w: 132, h: 62 },
  'case-zero': { x: 860, y: 140, w: 300, h: 150 },
  console: { x: 990, y: 366, w: 124, h: 68 },
}

/* The six checks stack down the left of the service and feed the rules block beside them. The
   rules were underneath, where six connectors fanned down into one bar and read as a tangle;
   side by side they are six short arrows pointing the same way, which is what they are. */
const CHECK_X = 188
const CHECK_W = 168
const CHECK_H = 38
const CHECK_Y = 46
const CHECK_GAP = 7
const RULES: Box = { x: 378, y: 46, w: 234, h: 264 }

const checkBox = (index: number): Box => ({
  x: CHECK_X,
  y: CHECK_Y + index * (CHECK_H + CHECK_GAP),
  w: CHECK_W,
  h: CHECK_H,
})

/* The three bands - who asks, what decides, what it rests on - as colour rather than as three
   more headings. None is a status colour: the design system keeps red, amber and green for what
   the service decided, never for what a box is. */
const BAND: Record<string, string> = {
  app: 'var(--fn-info)',
  console: 'var(--fn-info)',
  trusted: 'var(--fn-info)',
  'risk-mw': 'var(--fn-primary)',
  'case-zero': 'var(--fn-primary)',
  firestore: 'var(--fn-accent)',
  artefacts: 'var(--fn-accent)',
  ledger: 'var(--fn-accent)',
  gemini: 'var(--fn-accent)',
}

/** A phone is drawn as a phone, a database as a cylinder. A reader should know what a box is
    before reading its label. */
const SHAPE: Record<string, (b: Box) => JSX.Element> = {
  app: (b) => <PhoneShape {...b} />,
  console: (b) => <ScreenShape {...b} />,
  trusted: (b) => <PhoneShape {...b} />,
  firestore: (b) => <DatabaseShape {...b} />,
  ledger: (b) => <DatabaseShape {...b} />,
  artefacts: (b) => <FilesShape {...b} />,
  gemini: (b) => <SparkShape {...b} />,
}

/** The one model the investigator runs sits inside it, like the checks sit inside the service. */
/** The speeds the slider steps through. */
const SPEEDS = [0.3, 0.5, 0.7, 1, 1.5, 2, 3]

/** `ATO_BEHAVIOUR_MISMATCH_COLD_START` is wider than the block it has to live in. The suffix says
    the verdict came from the population model, which the line beneath it already says in words,
    so the block shows the code up to that point. The whole code stays on the hover. */
/** How far to push a label off its line, perpendicular to it, always towards the top. */
function labelLift(a: { x: number; y: number }, b: { x: number; y: number }) {
  const dx = b.x - a.x
  const dy = b.y - a.y
  const len = Math.hypot(dx, dy) || 1
  // The normal, flipped so it always points up the screen.
  const nx = -dy / len
  const ny = dx / len
  const sign = ny > 0 ? -1 : 1
  return { x: nx * 13 * sign, y: ny * 13 * sign - 2 }
}

const shortCode = (code: string) => code.replace(/_COLD_START$/, '')

const CZ_MODEL: Box = { x: 876, y: 202, w: 268, h: 54 }

const centre = (id: string) => {
  const box = NODE[id]!
  return { x: box.x + box.w / 2, y: box.y + box.h / 2 }
}

/** Where an arrow should leave a box: its edge, not its centre. */
function anchor(from: string, to: string) {
  const a = centre(from)
  const b = centre(to)
  const box = NODE[from]!
  const dx = b.x - a.x
  const dy = b.y - a.y
  if (Math.abs(dy) * box.w > Math.abs(dx) * box.h) {
    return { x: a.x + (dx / Math.abs(dy || 1)) * (box.h / 2), y: a.y + Math.sign(dy) * (box.h / 2) }
  }
  return { x: a.x + Math.sign(dx) * (box.w / 2), y: a.y + (dy / Math.abs(dx || 1)) * (box.w / 2) }
}

export function SystemView() {
  const { t, lang } = useT()
  const bn = lang === 'bn'
  const [map, setMap] = useState<Architecture | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [picked, setPicked] = useState<string | null>(null)
  const [journeyAt, setJourneyAt] = useState<number | null>(null)
  const [deep, setDeep] = useState(false)

  /* The player. `at` is the step on screen; null means nothing is playing and the picture is in
     its resting state. */
  const [runs, setRuns] = useState<Scenario[]>([])
  const [pickedRun, setPickedRun] = useState<string | null>(null)
  const [at, setAt] = useState<number | null>(null)
  const [paused, setPaused] = useState(false)
  /** Multiplier on the step time: 0.5x reads slowly, 3x skims. */
  const [speed, setSpeed] = useState(1)

  const run = runs.find((r) => r.id === pickedRun) ?? null
  const steps: Step[] = run ? stepsFor(run) : []
  const now: Step | null = at !== null ? steps[at] ?? null : null

  useEffect(() => {
    if (at === null || !run || paused) return
    if (at >= steps.length - 1) return
    // Slow enough to read a line before the next one replaces it, and adjustable because what is
    // comfortable to watch and what is comfortable to study are not the same speed.
    const timer = window.setTimeout(() => setAt(at + 1), 1500 / speed)
    return () => clearTimeout(timer)
  }, [at, run, steps.length, paused, speed])

  const play = (id: string) => {
    setPickedRun(id)
    setPicked(null)
    setPaused(false)
    setAt(0)
  }

  useEffect(() => {
    getArchitecture().then(setMap).catch((err: Error) => setError(err.message))
    getScenarios().then((payload) => setRuns(payload.scenarios)).catch(() => setRuns([]))
  }, [])

  if (error) return <Panel title={t('system.title')} question={t('system.q')}><div className="note bad">{error}</div></Panel>
  if (!map) return <Panel title={t('system.title')} question={t('system.q')}><div className="skeleton tall" /></Panel>

  const open = map.systems.find((s) => s.id === picked) ?? null
  const openModel = map.models.find((m) => m.id === picked) ?? null
  const openCheck = map.checks.find((c) => c.id === picked) ?? null
  const counts = map.risk_mw.counts
  /* While a scenario runs exactly one thing is lit - but a model's host has to stay lit with it,
     or the step that reads the payee scorer dims the very box the scorer lives in. */
  const lit = (id: string) => {
    if (now) {
      if (now.node === id) return true
      return map.models.find((m) => m.id === now.node)?.inside === id
    }
    return picked === null || picked === id || map.links.some((l) =>
      (l.from === picked && l.to === id) || (l.to === picked && l.from === id))
  }
  const edgeLit = (from: string, to: string) => {
    if (now) return now.edge === `${from}>${to}`
    return picked === null || picked === from || picked === to
  }

  return (
    <>
      <Panel title={t('system.title')} question={t('system.q')} info="system">
        <div className="toolbar runbar">
          {runs.map((r) => (
            <button
              key={r.id}
              className={`sm${pickedRun === r.id ? ' on' : ''}`}
              onClick={() => play(r.id)}
            >
              ▶ {bn ? r.name_bn : r.name}
            </button>
          ))}
          {at !== null && (
            <>
              <span className="spacer" />
              <button
                className="sm"
                onClick={() => { setPaused(true); setAt(Math.max(0, (at ?? 0) - 1)) }}
                disabled={(at ?? 0) === 0}
                title={t('system.back')}
              >
                ◀
              </button>
              <button className="sm" onClick={() => setPaused(!paused)}>
                {paused ? `▶ ${t('system.resume')}` : `❚❚ ${t('system.pause')}`}
              </button>
              <button
                className="sm"
                onClick={() => { setPaused(true); setAt(Math.min(steps.length - 1, (at ?? 0) + 1)) }}
                disabled={(at ?? 0) >= steps.length - 1}
                title={t('system.forward')}
              >
                ▶
              </button>
              <label className="speed">
                <span className="dim">{t('system.speed')}</span>
                {/* Below 1x as well as above it: reading the arithmetic takes longer than
                    watching the shape of the run. */}
                <input
                  type="range"
                  min="0"
                  max={SPEEDS.length - 1}
                  step="1"
                  value={SPEEDS.indexOf(speed)}
                  onChange={(event) => setSpeed(SPEEDS[Number(event.target.value)] ?? 1)}
                />
                <span className="mono">{speed}×</span>
              </label>
              <button className="sm ghost" onClick={() => { setAt(null); setPickedRun(null); setPaused(false) }}>
                {t('system.stop')}
              </button>
            </>
          )}
        </div>

        <div className="graph-wrap">
          <div className="graph-stage">
          <svg viewBox={`0 0 ${W} ${H}`} className="sysgraph" role="img">
            <defs>
              <marker id="ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                <path d="M0,0 L10,5 L0,10 z" fill="currentColor" />
              </marker>
              <marker id="feedarrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" markerHeight="5" orient="auto">
                <path d="M0,0 L10,5 L0,10 z" fill="currentColor" />
              </marker>
            </defs>

            {map.links.map((link) => {
              let a = anchor(link.from, link.to)
              let b = anchor(link.to, link.from)
              /* The phone asks and the service answers, and both were drawn on the same line, so
                 the two labels sat on top of each other. A pair that talks both ways gets a lane
                 each, pushed to opposite sides of where the single line used to run. */
              const twoWay = map.links.some((other) => other.from === link.to && other.to === link.from)
              if (twoWay) {
                const dx = b.x - a.x
                const dy = b.y - a.y
                const len = Math.hypot(dx, dy) || 1
                const off = 11
                // Perpendicular to the direction of travel, so each lane keeps its own side.
                const nx = (-dy / len) * off
                const ny = (dx / len) * off
                a = { x: a.x + nx, y: a.y + ny }
                b = { x: b.x + nx, y: b.y + ny }
              }
              const on = edgeLit(link.from, link.to)
                const live = Boolean(now && now.edge === `${link.from}>${link.to}`)
                return (
                <g key={`${link.from}-${link.to}`} className={`edge${on ? '' : ' faded'}${live ? ' live' : ''}`}>
                  <line x1={a.x} y1={a.y} x2={b.x} y2={b.y} markerEnd="url(#ar)" />
                  {/* The travelling dots. Only on the edge the payment is crossing this instant -
                      a diagram where everything moves says nothing about where anything is. */}
                  {live && (
                    <>
                      <line className="flow" x1={a.x} y1={a.y} x2={b.x} y2={b.y} />
                      {[0, 0.33, 0.66].map((offset) => (
                        <circle key={offset} className="spark" r="3">
                          <animateMotion
                            dur="1.2s"
                            repeatCount="indefinite"
                            begin={`${offset * 1.2}s`}
                            path={`M${a.x},${a.y} L${b.x},${b.y}`}
                          />
                        </circle>
                      ))}
                    </>
                  )}
                  {/* Four tenths along rather than halfway: the arrows are short now, and a label
                      at the midpoint sat on the box it was pointing at. */}
                </g>
              )
            })}

            {map.systems.map((box) => {
              const pos = NODE[box.id]
              if (!pos) return null
              const held = map.models.filter((m) => m.inside === box.id)
              const isHost = held.length > 0
              return (
                <g
                  key={box.id}
                  className={`node n-${box.id}${picked === box.id ? ' on' : ''}${lit(box.id) ? '' : ' faded'}${
                    isHost ? ' host' : ''
                  }`}
                  onClick={() => setPicked(picked === box.id ? null : box.id)}
                >
                  {SHAPE[box.id] ? (
                    <g style={{ color: BAND[box.id] }}>{SHAPE[box.id]!(pos)}</g>
                  ) : (
                    <>
                      {/* Square, because the design system's radius is zero. */}
                      <rect
                        x={pos.x}
                        y={pos.y}
                        width={pos.w}
                        height={pos.h}
                        fill={`color-mix(in srgb, ${BAND[box.id]} 12%, var(--fn-surface-variant))`}
                      />
                      <rect className="band" x={pos.x} y={pos.y} width="5" height={pos.h} fill={BAND[box.id]} />
                    </>
                  )}
                  {/* A host names itself along the top; a plain box names itself in the middle. */}
                  <text
                    className="label"
                    x={isHost ? pos.x + 18 : pos.x + pos.w / 2}
                    y={isHost ? pos.y + 26 : pos.y + pos.h + 18}
                    textAnchor={isHost ? 'start' : 'middle'}
                  >
                    {bn ? box.name_bn : box.name}
                  </text>
                </g>
              )
            })}

            {/* Inside the decision service: the checks, and the rules bar they feed. Each check
                names the module or model that answers it, and a stub says it is a stub - a box
                that looks like a model and is not one would be the worst thing here. */}
            {map.checks.map((check, index) => {
              const box = checkBox(index)
              const stub = check.badge === 'STUB'
              const on = now?.node === check.id
              return (
                <g
                  key={check.id}
                  className={`check${stub ? ' stub' : ''}${on ? ' on' : ''}${
                    now ? (on ? '' : ' faded') : lit('risk-mw') ? '' : ' faded'
                  }`}
                  onClick={(event) => {
                    event.stopPropagation()
                    setPicked(picked === check.id ? null : check.id)
                  }}
                >
                  <rect x={box.x} y={box.y} width={box.w} height={box.h} />
                  <rect className="pip" x={box.x} y={box.y} width={box.w} height="3" />
                  <text x={box.x + 11} y={box.y + 24}>{check.label}</text>
                  <text className="sub" x={box.x + box.w - 11} y={box.y + 24} textAnchor="end">
                    {check.badge === 'STUB' ? t('system.stub.short') : check.version ?? check.id}
                  </text>
                  {/* Every check feeds the merge. */}
                  <line
                    className="feed"
                    x1={box.x + box.w}
                    y1={box.y + box.h / 2}
                    x2={RULES.x}
                    y2={box.y + box.h / 2}
                    markerEnd="url(#feedarrow)"
                  />
                </g>
              )
            })}

            <g
              className={`rulesbar${now?.node === 'rules' ? ' on' : ''}${
                now ? (now.node === 'rules' ? '' : ' faded') : lit('risk-mw') ? '' : ' faded'
              }`}
              onClick={(event) => { event.stopPropagation(); setPicked(picked === 'rules' ? null : 'rules') }}
            >
              <rect x={RULES.x} y={RULES.y} width={RULES.w} height={RULES.h} />
              <text className="rules-title" x={RULES.x + 12} y={RULES.y + 20}>{t('system.rules')}</text>
              {/* The arithmetic, filling in as it happens. A code appears the moment the check
                  that fires it is read, so the block is seen accumulating rather than arriving
                  complete at the end. `decide()` takes the largest weight, so that is the sum. */}
              {(() => {
                if (!run) {
                  return <text className="rules-line dim" x={RULES.x + 12} y={RULES.y + 46}>{t('system.rules.idle')}</text>
                }
                const seenIds = new Set(
                  steps.slice(0, (at ?? 0) + 1).map((st) => st.check?.id).filter(Boolean) as string[],
                )
                const reported = run.checks.filter((c) => seenIds.has(c.id))
                const done = (at ?? 0) >= steps.length - 1 ||
                  steps.slice(0, (at ?? 0) + 1).some((st) => st.stage === 'merge')
                if (reported.length === 0) {
                  return <text className="rules-line dim" x={RULES.x + 12} y={RULES.y + 46}>{t('system.rules.idle')}</text>
                }
                return (
                  <>
                    {reported.map((c, i) => (
                      <g key={c.id} className={`rules-row v-${c.verdict}`}>
                        <text className="rules-mark" x={RULES.x + 12} y={RULES.y + 44 + i * 22}>
                          {c.verdict === 'raised' ? '▲' : c.verdict === 'off' ? '–' : '✓'}
                        </text>
                        <text className="rules-line" x={RULES.x + 28} y={RULES.y + 44 + i * 22}>
                          {c.code ? shortCode(c.code) : c.label}
                          <title>{c.code ?? c.label} · {c.test}</title>
                        </text>
                        <text className="rules-w" x={RULES.x + RULES.w - 12} y={RULES.y + 44 + i * 22} textAnchor="end">
                          {c.weight ?? ''}
                        </text>
                      </g>
                    ))}
                    {done && (
                      <>
                        <line
                          className="rules-rule"
                          x1={RULES.x + 12}
                          y1={RULES.y + 54 + reported.length * 22}
                          x2={RULES.x + RULES.w - 12}
                          y2={RULES.y + 54 + reported.length * 22}
                        />
                        <text className="rules-sum" x={RULES.x + 12} y={RULES.y + 76 + reported.length * 22}>
                          max {run.risk_score} → {run.decision}
                        </text>
                      </>
                    )}
                  </>
                )
              })()}
            </g>

            {/* The investigator's one model, drawn inside it the same way. */}
            {map.models.filter((m) => m.inside === 'case-zero').map((model) => {
              const on = now?.node === model.id
              return (
                <g
                  key={model.id}
                  className={`model${on ? ' on' : ''}${
                    now ? (on ? '' : ' faded') : lit('case-zero') ? '' : ' faded'
                  }`}
                  onClick={(event) => { event.stopPropagation(); setPicked(picked === model.id ? null : model.id) }}
                >
                  <rect x={CZ_MODEL.x} y={CZ_MODEL.y} width={CZ_MODEL.w} height={CZ_MODEL.h} />
                  <text className="mid" x={CZ_MODEL.x + 14} y={CZ_MODEL.y + 24}>{model.id}</text>
                  <text className="sub" x={CZ_MODEL.x + 14} y={CZ_MODEL.y + 42}>{model.version ?? ''}</text>
                </g>
              )
            })}

            {/* The labels, last - so they are simply in front of the boxes rather than behind
                them. Nothing else: no stroke, no chip. The only thing that was ever wrong with
                them was the order they were drawn in. */}
            {map.links.map((link) => {
              let a = anchor(link.from, link.to)
              let b = anchor(link.to, link.from)
              const twoWay = map.links.some((other) => other.from === link.to && other.to === link.from)
              if (twoWay) {
                const dx = b.x - a.x
                const dy = b.y - a.y
                const len = Math.hypot(dx, dy) || 1
                a = { x: a.x + (-dy / len) * 11, y: a.y + (dx / len) * 11 }
                b = { x: b.x + (-dy / len) * 11, y: b.y + (dx / len) * 11 }
              }
              const lift = labelLift(a, b)
              return (
                <text
                  key={`${link.from}-${link.to}-label`}
                  className={`edge-label${edgeLit(link.from, link.to) ? '' : ' faded'}`}
                  x={a.x + (b.x - a.x) * 0.4 + lift.x}
                  y={a.y + (b.y - a.y) * 0.4 + lift.y}
                  textAnchor="middle"
                >
                  {bn ? link.label_bn : link.label}
                </text>
              )
            })}
          </svg>
          {/* No callout at the merge: the rules bar is showing the same arithmetic, and the two
              of them sat on top of each other. */}
          {run && now && now.stage !== 'merge' && (() => {
            /* The caption follows the thing it is about. A band under the picture meant looking
               away from the picture to find out what was happening in it. */
            const where =
              NODE[now.node] ??
              (map.checks.some((c) => c.id === now.node)
                ? checkBox(map.checks.findIndex((c) => c.id === now.node))
                : now.node === 'rules'
                  ? RULES
                  : CZ_MODEL)
            // The SVG scales with the panel, so the callout is placed in percentages of it.
            const centreX = where.x + where.w / 2
            const below = where.y + where.h + 26 < H - 70
            const top = ((below ? where.y + where.h + 10 : where.y - 10) / H) * 100
            /* Centred on its node, except near an edge, where a centred box hangs off the panel
               and gets clipped - which is what happened to the answer card beside the phone. */
            const side = centreX < W * 0.26 ? 'left' : centreX > W * 0.74 ? 'right' : 'mid'
            const anchorX = side === 'left' ? where.x : side === 'right' ? where.x + where.w : centreX
            return (
              <div
                className={`graph-callout at-${side}${below ? '' : ' above'}`}
                style={{ left: `${(anchorX / W) * 100}%`, top: `${top}%` }}
              >
                <span className="callout-say">
                  {now.stage === 'send' && <>{bn ? run.story_bn : run.story}</>}
                  {now.stage === 'check' && now.check && (
                    /* What this check concluded, and the comparison it concluded it from - with
                       the engine's own threshold, so a reader can check the arithmetic. */
                    <>
                      <span className="dim">{now.check.label}</span>{' '}
                      <b className="mono">{now.check.test}</b>{' '}
                      {now.check.id === 'scam' && <span className="dim">· {t('system.byGemini')} </span>}
                      {now.check.verdict === 'raised' ? (
                        <span className="t-text-warn mono">▲ {now.check.code}</span>
                      ) : now.check.verdict === 'off' ? (
                        <span className="dim">– {t('system.v.off')}</span>
                      ) : (
                        <span className="t-text-good">✓ {t('system.v.clear')}</span>
                      )}
                    </>
                  )}
                  {now.stage === 'write' && <>{t('system.write.say')}</>}
                  {now.stage === 'notify' && <>{t('system.notify.say')}</>}
                  {now.stage === 'investigate' && (
                    <span className="t-text-warn">
                      {run.watchlisted ? `${t('system.watchlist.say')} (${run.watchlisted})` : t('system.investigate.say')}
                    </span>
                  )}
                  {now.stage === 'answer' && (
                    <span className="answer-card">
                      <span className="answer-head">
                        <span className={`mark t-${outcomeMark(run.decision).tone}`}>{outcomeMark(run.decision).mark}</span>{' '}
                        <b className={`t-text-${outcomeMark(run.decision).tone}`}>{run.decision}</b>
                        <span className="mono dim"> · {run.band} · {run.risk_score}</span>
                      </span>
                      <span className="answer-say">
                        {run.hits.length > 0
                          ? (bn ? run.hits[run.hits.length - 1]!.text_bn : run.hits[run.hits.length - 1]!.text_en)
                          : t('system.answer.clear')}
                      </span>
                    </span>
                  )}
                </span>
              </div>
            )
          })()}

          {run && (
            <div className="runline-bar on-stage">
              {steps.map((_, i) => (
                <span key={i} className={`tick${i <= (at ?? -1) ? ' done' : ''}`} />
              ))}
            </div>
          )}
          </div>
        </div>

        {open ? (
          <div className="note info">
            <div>
              <b>{bn ? open.name_bn : open.name}</b> <Badge kind={open.badge} />{' '}
              <span className="mono dim">{open.where}</span>
              <p>{bn ? open.what_bn : open.what}</p>
            </div>
          </div>
        ) : openCheck ? (
          <div className="note info">
            <div>
              <b>{openCheck.label}</b> <Badge kind={openCheck.badge} />{' '}
              <span className="mono dim">{openCheck.version ?? openCheck.id}</span>
              <p>{bn ? openCheck.asks_bn : openCheck.asks}</p>
            </div>
          </div>
        ) : openModel ? (
          <div className="note info">
            <div>
              <b className="mono">{openModel.id}</b> <Badge kind={openModel.badge} />{' '}
              <span className="mono dim">{openModel.version ?? '—'}</span>
              <p>{bn ? openModel.job_bn : openModel.job}</p>
              <span className="mono dim">{openModel.headline ?? '—'}</span>
            </div>
          </div>
        ) : run ? null : (
          <p className="panel-note">{t('system.pick')}</p>
        )}
      </Panel>

      <Panel title={t('system.journey')} question={t('system.journey.q')}>
        <div className="flowstrip">
          {map.journey.map((s) => (
            <button
              key={s.step}
              className={`flowstep${journeyAt === s.step ? ' on' : ''}`}
              onClick={() => setJourneyAt(journeyAt === s.step ? null : s.step)}
            >
              <span className="flownum">{n(s.step)}</span>
              <span>{bn ? s.title_bn : s.title}</span>
            </button>
          ))}
        </div>
        {(() => {
          const s = map.journey.find((j) => j.step === journeyAt)
          return s ? (
            <div className="note info">
              <div>
                <p>{bn ? s.plain_bn : s.plain}</p>
                <span className="mono dim">{s.route} · {s.module}</span>
              </div>
            </div>
          ) : (
            <p className="panel-note">{t('system.pickstep')}</p>
          )
        })()}
      </Panel>

      <Panel
        title={t('system.inside')}
        question={`${n(counts.routes)} · ${n(counts.modules)} · ${n(counts.reaching_gemini)} ${t('system.ongemini')}`}
        right={<button className="sm" onClick={() => setDeep(!deep)}>{deep ? t('system.hide') : t('system.show')}</button>}
      >
        {deep && (
          <>
            <div className="table-wrap">
              <table>
                <thead>
                  <tr><th>{t('system.router')}</th><th>{t('system.routes')}</th></tr>
                </thead>
                <tbody>
                  {map.risk_mw.routers.map((r) => (
                    <tr key={r.id}>
                      <td><b>{r.id}</b> <span className="mono dim">{r.prefix}</span></td>
                      <td>
                        {r.routes.map((route) => (
                          <div key={`${route.method}${route.path}`} className="mono">
                            <span className="dim">{route.method}</span> {route.path}
                          </div>
                        ))}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="modgrid" style={{ marginTop: 12 }}>
              {map.risk_mw.modules.map((m) => (
                <span key={m.id} className="modchip" title={m.file}>
                  <span className="mono">{m.id}</span>
                  {m.reaches.map((r) => (
                    <Chip key={r} kind={r === 'gemini' ? 'violet' : 'muted'}>{r}</Chip>
                  ))}
                </span>
              ))}
            </div>
            <p className="panel-note">{t('system.source')}</p>
          </>
        )}
      </Panel>
    </>
  )
}
