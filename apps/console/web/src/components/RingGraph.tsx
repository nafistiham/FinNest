/**
 * The ring in three dimensions, drawn only from what Case Zero returned.
 *
 * Every node and every edge here came out of a named tool call in a recorded investigation - the
 * `graph_delta` each tool result carries. Nothing is inferred, nothing is laid out by hand, and no
 * edge exists because it would look better if it did. Hovering a node says which call found it,
 * which is the same standard the case text is held to: a picture of a fraud ring is a serious
 * claim about people, and this one can be taken apart back to its source.
 *
 * What the picture emphasises, though, is a choice, and this version makes it the obvious one. An
 * earlier pass coloured a node by what the account is and left a watch-listed account its own
 * colour, on the reasoning that "what it is" and "what an investigation said about it" are two
 * readings. That is true and it was still wrong: forty-eight accounts in six colours is a hairball,
 * and the six that an investigation actually implicated disappeared into it. So the implicated
 * accounts are red and lit, everything else recedes, and the kind is told by shape and by the
 * hover line instead. The red comes from the server's own `role` field - mule_L1, mule_L2 - never
 * from anything computed here.
 *
 * The library is loaded on demand. three.js is most of a megabyte and nobody who never opens this
 * view should pay for it.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import type { RingGraphData, RingNode } from '../lib/types'
import { useT } from '../lib/i18n'
import { digits, n, taka } from '../lib/format'
import { Icon } from './Wordmark'

/* Every colour here is a token from design-system/tokens.json, and now from its *light*
   palette rather than its dark one. The panel is a lit canvas, so the accounts drawn on it want
   the deep, saturated values - #B3261E rather than #F2B8B5 - and the dark palette's light tints
   were built to sit on near-black, which is why they looked washed out here.

   The meanings are the system's and do not move with the palette: red is danger and only danger,
   amber is suspected-and-pending. mule_L1 is a confirmed danger; mule_L2 is an account an
   investigation suspects and the scorer rates near zero, which is exactly what amber is for. */
const SUSPECT: Record<string, { fill: string; text: string; glow: string }> = {
  mule_L1: { fill: '#B3261E', text: '#FFFFFF', glow: '#B3261E' },  // dangerFill / onDangerFill
  mule_L2: { fill: '#8A5A00', text: '#FFFFFF', glow: '#8A5A00' },  // warning
}
const SUSPECT_FALLBACK = SUSPECT.mule_L2!

/* Context accounts take a pale container of their own kind with the deep value as ring and text,
   so a till, a merchant and a customer are plainly different without any of them competing with
   the six an investigation actually named - those are the only solid fills on the panel. */
const CONTEXT_FILL = '#FDFCF9'   // surface, a shade off white
const KIND: Record<string, string> = {
  customer: '#1F5FA8',          // info
  agent_till: '#0F6E67',        // primary
  merchant: '#7B4B94',          // accent
  agent: '#5F7F36',             // brandLeaf, darkened for text weight on a pale fill
  onboarding_agent: '#5F7F36',
  payroll: '#5B5F66',           // mutedText
  unknown: '#878C88',           // outline
}
const KIND_FALLBACK = '#878C88'

const EDGE: Record<string, string> = {
  money: '#0F6E67',             // primary
  proximity: '#7B4B94',         // accent
  link: '#5F7F36',              // brandLeaf
}
const HOT_EDGE = '#B3261E'      // danger
const EDGE_FALLBACK = '#878C88' // outline

/** The distance the discs were sized for; closer or further, the frame loop corrects for it.

    There is no reveal threshold any more: every account carries its own id inside its own circle
    at every zoom, which is what it should have been doing all along. */
const LABEL_REFERENCE_DISTANCE = 260

const isSuspect = (node: { role?: string | null }) => Boolean(node.role)
const suspectPaint = (node: any) => SUSPECT[node.role] ?? SUSPECT_FALLBACK
const kindColour = (node: any): string => KIND[node.kind] ?? KIND_FALLBACK
/** The colour a legend swatch and a hover line use for this account. */
const nodeColour = (node: any): string => (isSuspect(node) ? suspectPaint(node).fill : kindColour(node))

/** `acct_till_AG-0014` is the account; `AG-0014` is what fits inside a circle and still names it. */
const shortId = (id: string) =>
  id.replace(/^acct_/, '').replace(/^(till|merchant|payroll|agent)_/, '')

const rgb = (hex: string) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16))

/** `colour` laid over `base` at `amount`, so a context account's fill carries its own kind. */
function tint(colour: string, amount: number, base: string): string {
  const [r1, g1, b1] = rgb(colour)
  const [r0, g0, b0] = rgb(base)
  const mix = (a: number, b: number) => Math.round(b + (a - b) * amount)
  return `rgb(${mix(r1!, r0!)}, ${mix(g1!, g0!)}, ${mix(b1!, b0!)})`
}

const hexA = (hex: string, alpha: number) => {
  const [r, g, b] = rgb(hex)
  return `rgba(${r}, ${g}, ${b}, ${alpha})`
}

/**
 * One account, drawn as a disc that always faces the camera.
 *
 * Spheres were the obvious choice and the wrong one. A sphere off the centre of a perspective
 * projection is an ellipse - that is what the projection does, not a bug - so accounts at the edge
 * visibly stopped being circles as soon as anyone zoomed. A sprite is screen-aligned, so it is
 * perfectly round everywhere, at every zoom, and it gives the id somewhere to live: inside the
 * circle rather than floating beside it.
 *
 * Glow, disc and text are one texture. As separate sprites at the same position there is no
 * reliable order between them, and an additively-blended halo drawn over its own node washed the
 * fill out - which is how the one colour that had to stay red came out pink.
 */
function nodeSprite(THREE: any, node: any) {
  const suspect = isSuspect(node)
  const paint = suspect ? suspectPaint(node) : null
  const kind = kindColour(node)
  const fill = paint ? paint.fill : tint(kind, 0.24, CONTEXT_FILL)
  const edge = paint ? paint.glow : kind
  const text = paint ? paint.text : kind
  const label = shortId(node.id)

  const S = 256
  const canvas = document.createElement('canvas')
  canvas.width = canvas.height = S
  const ctx = canvas.getContext('2d')!
  const c = S / 2
  const r = suspect ? S * 0.3 : S * 0.345

  // An implicated account carries its own light. Nothing else on the panel glows.
  if (suspect) {
    const glow = ctx.createRadialGradient(c, c, r * 0.96, c, c, r * 1.42)
    glow.addColorStop(0, hexA(edge, 0.34))
    glow.addColorStop(0.5, hexA(edge, 0.11))
    glow.addColorStop(1, hexA(edge, 0))
    ctx.fillStyle = glow
    ctx.fillRect(0, 0, S, S)
  }

  ctx.beginPath()
  ctx.arc(c, c, r, 0, Math.PI * 2)
  ctx.fillStyle = fill
  ctx.fill()
  ctx.lineWidth = suspect ? 7 : 6
  ctx.strokeStyle = edge
  ctx.stroke()

  // Shrink to fit rather than clip: an id that does not fit is an id nobody can read.
  let size = 62
  const fits = () => {
    ctx.font = `700 ${size}px ui-monospace, SFMono-Regular, Menlo, monospace`
    return ctx.measureText(label).width <= r * 1.6
  }
  while (!fits() && size > 18) size -= 2
  ctx.textAlign = 'center'
  ctx.textBaseline = 'middle'
  ctx.fillStyle = text
  ctx.fillText(label, c, c + 1)

  const texture = new THREE.CanvasTexture(canvas)
  texture.minFilter = THREE.LinearMipmapLinearFilter
  texture.generateMipmaps = true
  const sprite = new THREE.Sprite(
    // A link is drawn between two node positions, which means between two node centres, so every
    // edge arriving at an account ran straight across its id. Rather than shortening fifty links
    // - which the library does not offer and which would have to be recomputed every frame as the
    // simulation moves - the disc is drawn after them and over them. The part of the link inside
    // the circle is covered by the circle, so the edge appears to meet the account at its rim,
    // which is all it ever needed to do.
    //
    // depthTest off with an explicit renderOrder puts every disc above every link. Discs still
    // sort correctly against each other: three.js orders the transparent pass back to front, so a
    // nearer account is still drawn over a further one.
    new THREE.SpriteMaterial({ map: texture, transparent: true, depthWrite: false, depthTest: false }),
  )
  sprite.renderOrder = 2
  // Size still carries degree, which is a fact about the graph and not a judgement about the
  // account - with a floor, because a circle too small to hold its own name is a dot.
  const d = (suspect ? 26 : 17) + Math.min(18, (node.degree ?? 0) * 0.6)
  sprite.scale.set(d, d, 1)
  sprite.userData.baseScale = { x: d, y: d }
  // The texture is mostly transparent around the circle, so the drawn radius is a fraction of the
  // sprite. The links use this to know where the rim actually is.
  sprite.userData.solidFraction = r / S
  return sprite
}

export function RingGraph({
  data,
  onOpenAccount,
}: {
  data: RingGraphData
  onOpenAccount: (acctId: string) => void
}) {
  const { t } = useT()
  const holder = useRef<HTMLDivElement>(null)
  const graphRef = useRef<any>(null)
  const [hover, setHover] = useState<RingNode | null>(null)
  const [failed, setFailed] = useState<string | null>(null)
  const [pinned, setPinned] = useState(0)

  /* The camera flies to the middle of what the investigation implicated, which is the only part of
     this picture an operator opened it to look at. */
  const focusRing = useCallback(() => {
    const graph = graphRef.current
    if (!graph) return
    const suspects = graph.graphData().nodes.filter(isSuspect)
    if (!suspects.length) return
    const centre = suspects.reduce(
      (acc: any, node: any) => ({ x: acc.x + node.x / suspects.length, y: acc.y + node.y / suspects.length, z: acc.z + node.z / suspects.length }),
      { x: 0, y: 0, z: 0 },
    )
    const spread = Math.max(
      90,
      ...suspects.map((node: any) => Math.hypot(node.x - centre.x, node.y - centre.y, node.z - centre.z)),
    )
    graph.cameraPosition({ x: centre.x, y: centre.y, z: centre.z + spread * 3.2 }, centre, 1200)
  }, [])

  /** Drag-and-drop should leave a node where it was dropped; this undoes all of that at once. */
  const releasePins = useCallback(() => {
    const graph = graphRef.current
    if (!graph) return
    graph.graphData().nodes.forEach((node: any) => {
      node.fx = undefined
      node.fy = undefined
      node.fz = undefined
    })
    setPinned(0)
    graph.d3ReheatSimulation()
  }, [])

  useEffect(() => {
    let graph: any = null
    let cancelled = false
    let resize: (() => void) | null = null
    let stopReveal: (() => void) | null = null

    ;(async () => {
      try {
        const [{ default: ForceGraph3D }, THREE] = await Promise.all([
          import('3d-force-graph'),
          import('three'),
        ])
        if (cancelled || !holder.current) return

        const discs: { node: any; sprite: any }[] = []
        const nodes = data.nodes.map((node) => ({ ...node }))
        const links = data.edges.map((edge) => ({ ...edge }))
        const suspectIds = new Set(nodes.filter(isSuspect).map((node) => node.id))
        /* An edge is "hot" when it touches something the investigation implicated. That is a fact
           about the two endpoints the server gave us, not a judgement added here. */
        const hot = (link: any) =>
          suspectIds.has(typeof link.source === 'object' ? link.source.id : link.source) ||
          suspectIds.has(typeof link.target === 'object' ? link.target.id : link.target)

        graph = new (ForceGraph3D as any)(holder.current)
          /* Transparent, so the panel's own background is the ground. That is only possible
             without a post-processing composer, which is one more reason there is not one. */
          .backgroundColor('rgba(0,0,0,0)')
          .width(holder.current.clientWidth)
          .height(520)
          .showNavInfo(false)
          .graphData({ nodes, links })
          .nodeId('id')
          .nodeLabel((node: any) =>
            `<b>${node.id}</b> · ${node.kind}${node.role ? ` · <span style="color:${nodeColour(node)}">${node.role}</span>` : ''}` +
            `<br/><span style="opacity:.7">${t('ring.foundby')} ${node.found_by_tool} (${node.found_by})</span>`,
          )
          // The disc replaces the sphere entirely rather than sitting on top of one.
          .nodeThreeObjectExtend(false)
          .nodeThreeObject((node: any) => {
            const disc = nodeSprite(THREE, node)
            discs.push({ node, sprite: disc })
            return disc
          })
          .linkSource('source')
          .linkTarget('target')
          .linkColor((link: any) => (hot(link) ? HOT_EDGE : EDGE[link.kind] ?? EDGE_FALLBACK))
          .linkOpacity(0.62)
          .linkWidth((link: any) => (hot(link) ? 1.2 : link.kind === 'money' ? 0.55 : 0.35))
          /* Straight, because the link now positions itself and a bezier tube would mean
             rebuilding the curve geometry every frame for no gain. */
          .linkCurvature(0)
          /* A link is drawn between two node positions - two node centres - so every edge arriving
             at an account ran straight across the id printed inside it, and the hub with
             twenty-four of them was unreadable.

             Drawing the disc over the link was the cheap fix and it does not work: three.js sorts
             the transparent pass by the containing group before the object's own renderOrder, and
             the library keeps nodes and links in separate groups, so a node can never be promoted
             above a link from the outside. Tried, measured, discarded.

             So the link positions itself, pulled in at each end by that account's current radius -
             which the frame loop keeps on the node, because the discs are rescaled by distance.
             This is the library's own straight-tube placement with shortened endpoints. */
          .linkPositionUpdate((obj: any, { start, end }: any, link: any) => {
            const line = obj?.children?.length ? obj.children[0] : obj
            if (!line || line.type !== 'Mesh') return false

            const width = hot(link) ? 1.2 : link.kind === 'money' ? 0.55 : 0.35
            if (!/^Cylinder(Buffer)?Geometry$/.test(line.geometry?.type ?? '')) {
              const radius = width / 2
              const geometry = new THREE.CylinderGeometry(radius, radius, 1, 6, 1, false)
              geometry.applyMatrix4(new THREE.Matrix4().makeTranslation(0, 1 / 2, 0))
              geometry.applyMatrix4(new THREE.Matrix4().makeRotationX(Math.PI / 2))
              line.geometry?.dispose()
              line.geometry = geometry
            }

            const from = new THREE.Vector3(start.x, start.y ?? 0, start.z ?? 0)
            const to = new THREE.Vector3(end.x, end.y ?? 0, end.z ?? 0)
            const span = to.clone().sub(from)
            const length = span.length()
            if (length === 0) return true
            const unit = span.clone().divideScalar(length)

            const gapFrom = (link.source as any)?.__rimRadius ?? 0
            const gapTo = (link.target as any)?.__rimRadius ?? 0
            // Never turn a link inside out: two discs that overlap keep a hairline between them.
            const keep = Math.max(length * 0.08, length - gapFrom - gapTo)
            const slack = (length - keep) / 2
            const a = from.clone().add(unit.clone().multiplyScalar(Math.min(gapFrom, slack * 2) || 0))
            const b = to.clone().sub(unit.clone().multiplyScalar(Math.min(gapTo, slack * 2) || 0))

            line.position.copy(a)
            line.scale.z = a.distanceTo(b)
            const target = b.clone()
            line.parent?.localToWorld(target)   // lookAt wants world coordinates
            line.lookAt(target)
            return true
          })
          // Particles only where money moved through the ring, so motion means something.
          .linkDirectionalParticles((link: any) => (link.kind === 'money' && hot(link) ? 3 : 0))
          .linkDirectionalParticleWidth(1.8)
          .linkDirectionalParticleSpeed(0.006)
          .linkDirectionalParticleColor(() => HOT_EDGE)
          .linkLabel((link: any) =>
            link.kind === 'money'
              ? `${taka(link.amount_bdt ?? 0)} · ${link.txn_id ?? ''}<br/><span style="opacity:.7">${link.ts ?? ''}</span>`
              : `${link.kind} · ${t('ring.foundby')} ${link.found_by_tool}`,
          )
          .onNodeHover((node: any) => setHover(node ?? null))
          .onNodeClick((node: any) => {
            if (node?.id?.startsWith('acct_')) onOpenAccount(node.id)
          })
          // Dropped is dropped. Without this the simulation pulls the node straight back and the
          // drag reads as a bug rather than as a way to untangle the picture.
          .onNodeDragEnd((node: any) => {
            node.fx = node.x
            node.fy = node.y
            node.fz = node.z
            setPinned(graph.graphData().nodes.filter((n: any) => n.fx !== undefined).length)
          })

        /* One hub of degree 24 against forty-seven leaves collapses into a ball at the default
           charge; spreading it is what makes the ring legible as a ring. */
        graph.d3Force('charge').strength(-170).distanceMax(600)
        graph.d3Force('link').distance((link: any) => (link.kind === 'money' ? 46 : 70))

        /* No bloom. It was here to make the red read as heat and it did the opposite: a bright
           fill pushed through an UnrealBloomPass comes back white, so the one colour that had to
           stay red stopped being red, and amber and red became the same hot smear. It also forced
           an opaque clear colour, which is why the panel could not have a background of its own.
           The halo behind an implicated account does the same job honestly, in the account's own
           colour, at a size this file decides.

           If bloom ever comes back it needs an alpha-preserving composer and a threshold high
           enough that only the halo blooms - not the fill, and never the text. */

        /* Labels appear as you come closer. There is no render hook to hang this on, so it runs
           on its own frame loop and only touches `visible`, which costs nothing per frame. The
           threshold is in world units from the camera: far out you see the ring's shape and the
           six names that matter, close in every account says what it is without being asked. */
        const camera = graph.camera()
        let raf = 0
        const reveal = () => {
          for (const entry of discs) {
            const { x, y, z } = entry.node
            if (x === undefined) continue
            const distance = Math.hypot(camera.position.x - x, camera.position.y - y, camera.position.z - z)
            // The disc still grows and shrinks with distance like any object - it should, it is
            // an account in a space - but only within bounds, so a close zoom does not turn one
            // account into the whole panel and a far view does not shrink its id to a smudge.
            const base = entry.sprite.userData.baseScale
            const k = Math.min(1.5, Math.max(0.55, distance / LABEL_REFERENCE_DISTANCE))
            entry.sprite.scale.set(base.x * k, base.y * k, 1)
            // What the links need: the radius of the solid circle, in world units, right now.
            entry.node.__rimRadius = base.x * k * entry.sprite.userData.solidFraction
          }
          raf = requestAnimationFrame(reveal)
        }
        raf = requestAnimationFrame(reveal)
        stopReveal = () => cancelAnimationFrame(raf)

        graphRef.current = graph
        graph.cameraPosition({ z: 360 })
        graph.onEngineStop(() => focusRing())

        resize = () => holder.current && graph.width(holder.current.clientWidth)
        window.addEventListener('resize', resize)
      } catch (error) {
        setFailed((error as Error).message)
      }
    })()

    return () => {
      cancelled = true
      if (stopReveal) stopReveal()
      if (resize) window.removeEventListener('resize', resize)
      if (graph?._destructor) graph._destructor()
      graphRef.current = null
      if (holder.current) holder.current.innerHTML = ''
    }
  }, [data, onOpenAccount, focusRing])

  if (failed) {
    return (
      <div className="note bad" role="alert">
        <Icon name="error" />
        <div>
          {t('ring.failed')}: {failed}
          <div>{t('error.next')}</div>
        </div>
      </div>
    )
  }

  const roles = [...new Set(data.nodes.filter(isSuspect).map((node) => node.role as string))].sort()
  const kinds = [...new Set(data.nodes.filter((node) => !isSuspect(node)).map((node) => node.kind))].sort()

  return (
    <>
      <div className="ring-stage">
        <div className="ring-holder" ref={holder} />
        <div className="ring-tools">
          <button className="sm" onClick={focusRing} title={t('ring.focus.hint')}>
            <Icon name="filter_center_focus" />
            {t('ring.focus')}
          </button>
          <button className="sm ghost" onClick={releasePins} disabled={pinned === 0} title={t('ring.release.hint')}>
            <Icon name="restart_alt" />
            {t('ring.release')}{pinned > 0 ? ` (${n(pinned)})` : ''}
          </button>
        </div>
      </div>
      <div className="ring-legend">
        <span className="dim">{t('ring.suspect')}:</span>
        {roles.map((role) => (
          <span key={role}>
            <i className="lit" style={{ background: (SUSPECT[role] ?? SUSPECT_FALLBACK).glow }} />
            {role}
          </span>
        ))}
        <span className="dim">{t('ring.context')}:</span>
        {kinds.map((kind) => (
          <span key={kind}>
            <i style={{ background: KIND[kind] ?? KIND_FALLBACK }} />
            {kind}
          </span>
        ))}
        <span className="spacer" />
        <span className="dim">{t('ring.edges')}:</span>
        <span>
          <i style={{ background: HOT_EDGE }} />
          {t('ring.hot')}
        </span>
        {Object.entries(EDGE)
          .filter(([kind]) => data.edges.some((edge) => edge.kind === kind))
          .map(([kind, colour]) => (
            <span key={kind}>
              <i style={{ background: colour }} />
              {kind}
            </span>
          ))}
      </div>
      <div className="ring-hover">
        {hover ? (
          <>
            <b className="mono">{hover.id}</b> · {hover.kind}
            {hover.role && <> · <span className={`chip t-${hover.role === 'mule_L1' ? 'bad' : 'warn'}`}>{hover.role}</span></>}
            {hover.status && <> · {hover.status}</>}
            {hover.model_score !== undefined && hover.model_score !== null && (
              <> · p(mule) {digits(String(hover.model_score))}</>
            )}
            <span className="dim">
              {' '}· {t('ring.foundby')} {hover.found_by_tool} ({hover.found_by})
            </span>
          </>
        ) : (
          <span className="dim">{t('ring.hint')}</span>
        )}
      </div>
    </>
  )
}
