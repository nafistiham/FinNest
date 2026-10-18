/**
 * The shapes the system map is drawn with.
 *
 * A database is a cylinder, a phone is a phone, a console is a screen on a stand, and a file store
 * is a stack of sheets. Every one of these is the shape its thing has had in architecture diagrams
 * for decades, which is the point: a reader should know what a box is before reading its label.
 *
 * Each returns the artwork only. The caller positions it, colours it through `currentColor`, and
 * writes the label - so a shape never decides where it sits or what it is called.
 */

export function PhoneShape({ x, y, w, h }: { x: number; y: number; w: number; h: number }) {
  const inset = 7
  return (
    <>
      <rect className="shape" x={x} y={y} width={w} height={h} rx="8" />
      <rect className="screen" x={x + inset} y={y + inset + 6} width={w - inset * 2} height={h - inset * 2 - 14} />
      <line className="hair" x1={x + w / 2 - 10} y1={y + 8} x2={x + w / 2 + 10} y2={y + 8} />
      <rect className="hair-fill" x={x + w / 2 - 14} y={y + h - 9} width="28" height="3" rx="1.5" />
    </>
  )
}

/** The classic cylinder: a disc on top, a body, and the far rim showing at the bottom. */
export function DatabaseShape({ x, y, w, h }: { x: number; y: number; w: number; h: number }) {
  const ry = 11
  return (
    <>
      <path
        className="shape"
        d={`M${x},${y + ry} a${w / 2},${ry} 0 0 1 ${w},0 v${h - ry * 2} a${w / 2},${ry} 0 0 1 ${-w},0 z`}
      />
      <ellipse className="lid" cx={x + w / 2} cy={y + ry} rx={w / 2} ry={ry} />
      <path className="hair" d={`M${x},${y + ry + 14} a${w / 2},${ry} 0 0 0 ${w},0`} fill="none" />
      <path className="hair" d={`M${x},${y + ry + 28} a${w / 2},${ry} 0 0 0 ${w},0`} fill="none" />
    </>
  )
}

/** A screen on a stand. */
export function ScreenShape({ x, y, w, h }: { x: number; y: number; w: number; h: number }) {
  const screenH = h - 14
  return (
    <>
      <rect className="shape" x={x} y={y} width={w} height={screenH} rx="3" />
      <rect className="screen" x={x + 7} y={y + 7} width={w - 14} height={screenH - 14} />
      <rect className="hair-fill" x={x + w / 2 - 13} y={y + screenH} width="26" height="6" />
      <rect className="hair-fill" x={x + w / 2 - 30} y={y + screenH + 6} width="60" height="4" rx="2" />
    </>
  )
}

/** A stack of sheets: what "the weights on disk" actually is. */
export function FilesShape({ x, y, w, h }: { x: number; y: number; w: number; h: number }) {
  const sheet = h - 12
  return (
    <>
      <rect className="ghost" x={x + 10} y={y} width={w - 10} height={sheet} rx="2" />
      <rect className="ghost" x={x + 5} y={y + 6} width={w - 10} height={sheet} rx="2" />
      <rect className="shape" x={x} y={y + 12} width={w - 10} height={sheet} rx="2" />
      <line className="hair" x1={x + 10} y1={y + 28} x2={x + w - 24} y2={y + 28} />
      <line className="hair" x1={x + 10} y1={y + 38} x2={x + w - 32} y2={y + 38} />
    </>
  )
}

/** The four-pointed spark that means a model answered. */
export function SparkShape({ x, y, w, h }: { x: number; y: number; w: number; h: number }) {
  const cx = x + w / 2
  const cy = y + h / 2
  const r = Math.min(w, h) / 2
  const spark = (sx: number, sy: number, size: number) =>
    `M${sx},${sy - size} Q${sx + size * 0.18},${sy - size * 0.18} ${sx + size},${sy} ` +
    `Q${sx + size * 0.18},${sy + size * 0.18} ${sx},${sy + size} ` +
    `Q${sx - size * 0.18},${sy + size * 0.18} ${sx - size},${sy} ` +
    `Q${sx - size * 0.18},${sy - size * 0.18} ${sx},${sy - size} z`
  return (
    <>
      <rect className="shape" x={x} y={y} width={w} height={h} rx="3" />
      <path className="spark-fill" d={spark(cx, cy, r * 0.62)} />
      <path className="spark-fill dim" d={spark(cx + r * 0.72, cy - r * 0.46, r * 0.24)} />
    </>
  )
}
