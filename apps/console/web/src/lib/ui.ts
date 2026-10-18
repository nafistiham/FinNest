/**
 * The small pieces of application state that are not data: where you are, what you prefer, and
 * what just went wrong.
 *
 * Hash routing rather than a router dependency: six views, no nested routes, and the hash survives
 * a copy-paste into a Linear comment, which is the only thing a router would have bought us here.
 */

import { useEffect, useRef, useState } from 'react'

export type ViewId = 'overview' | 'gates' | 'risk' | 'accounts' | 'logs' | 'cases' | 'campaigns' | 'cashout' | 'models' | 'live' | 'settings'

/** Labels and hints come from the string table; this is only the order and the icons
    (Material Symbols Outlined names, the set the design system uses on the web; index.html loads
    exactly these glyphs, so a new icon needs adding there too). */
export const VIEWS: { id: ViewId; icon: string }[] = [
  { id: 'overview', icon: 'dashboard' },
  { id: 'gates', icon: 'shield' },
  { id: 'risk', icon: 'swap_horiz' },
  { id: 'accounts', icon: 'person_search' },
  { id: 'logs', icon: 'description' },
  { id: 'cases', icon: 'folder_open' },
  { id: 'campaigns', icon: 'radar' },
  { id: 'cashout', icon: 'local_atm' },
  { id: 'models', icon: 'monitoring' },
  { id: 'live', icon: 'sensors' },
  { id: 'settings', icon: 'settings' },
]

/** The sidebar in three groups, so eleven views read as three jobs: watch the defence, dig into a
    case, change how the console looks. Every view sits in exactly one group. */
export const VIEW_GROUPS: { id: 'monitor' | 'investigate' | 'console'; views: ViewId[] }[] = [
  { id: 'monitor', views: ['overview', 'gates', 'risk', 'live'] },
  { id: 'investigate', views: ['accounts', 'logs', 'cases', 'campaigns', 'cashout', 'models'] },
  { id: 'console', views: ['settings'] },
]

const isView = (value: string): value is ViewId => VIEWS.some((view) => view.id === value)

export function useHashView(): [ViewId, (id: ViewId) => void] {
  const read = (): ViewId => {
    const raw = window.location.hash.replace(/^#\/?/, '')
    return isView(raw) ? raw : 'overview'
  }
  const [view, setView] = useState<ViewId>(read)
  useEffect(() => {
    const onHash = () => setView(read())
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])
  const go = (id: ViewId) => {
    window.location.hash = `/${id}`
    setView(id)
  }
  return [view, go]
}

/* --- preferences -------------------------------------------------------- */

/** `system` follows the operating system, as the design system asks; the other two force a mode
    through `data-theme`, which finnest.css reads directly. */
export type Theme = 'system' | 'light' | 'dark'
export type Density = 'comfortable' | 'compact'
/** The design system's five colour presets (tokens.json `color.preset`), the same five the app's
    Settings offers. `teal` is the default and has no rule of its own in finnest.css. */
export type Preset = 'teal' | 'padma' | 'jamdani' | 'shapla' | 'slate'

/* Kept in step with the pre-paint script in index.html, which applies the same values. */
export const THEMES: readonly Theme[] = ['system', 'light', 'dark']
export const DENSITIES: readonly Density[] = ['comfortable', 'compact']
export const PRESETS: readonly Preset[] = ['teal', 'padma', 'jamdani', 'shapla', 'slate']

/**
 * A remembered preference, mirrored onto <html> as `data-<last word of the key>`.
 *
 * The language also sets `lang`, because finnest.css switches the whole type scale (SolaimanLipi
 * and the Bangla sizes, or Roboto and the Latin ones) on `:lang(bn)` / `:lang(en)`, and screen
 * readers pick their voice from it. index.html applies the stored values before first paint.
 *
 * `allowed` guards against a stored value no rule matches (an older build's, or a hand edit):
 * it falls back instead of leaving the page between modes.
 */
export function usePref<T extends string>(key: string, fallback: T, allowed?: readonly T[]): [T, (value: T) => void] {
  const [value, setValue] = useState<T>(() => {
    try {
      const stored = localStorage.getItem(key) as T | null
      if (stored === null || (allowed && !allowed.includes(stored))) return fallback
      return stored
    } catch {
      return fallback
    }
  })
  const first = useRef(true)
  useEffect(() => {
    const name = key.split('-').pop()!
    /* After first paint, a theme or palette change cross-fades for one slow beat (styles.css,
       .theme-switching); on load the pre-paint script already set it, so nothing animates. */
    if (!first.current && (name === 'theme' || name === 'preset')) crossFade()
    first.current = false
    try {
      localStorage.setItem(key, value)
    } catch {
      /* private window: the preference lasts for this visit only */
    }
    document.documentElement.dataset[name] = value
    if (name === 'lang') document.documentElement.lang = value
    if (name === 'theme' || name === 'preset') syncThemeColor((document.documentElement.dataset.theme ?? 'system') as Theme)
  }, [key, value])
  return [value, setValue]
}

let crossFadeTimer = 0
function crossFade(): void {
  const wait = durationMs('slow')
  if (wait <= 0) return
  const root = document.documentElement
  root.classList.add('theme-switching')
  window.clearTimeout(crossFadeTimer)
  crossFadeTimer = window.setTimeout(() => root.classList.remove('theme-switching'), wait + 50)
}

/** The browser chrome (a phone's address bar) takes the page's surface in the chosen mode, read
    from the tokens after the mode has switched, and follows the OS while the theme is `system`. */
let themeQuery: MediaQueryList | null = null
function syncThemeColor(theme: Theme): void {
  const apply = () => {
    const surface = getComputedStyle(document.documentElement).getPropertyValue('--fn-surface').trim()
    if (!surface) return
    document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]').forEach((meta) => {
      meta.removeAttribute('media')
      meta.content = surface
    })
  }
  apply()
  if (typeof window.matchMedia !== 'function') return
  themeQuery ??= window.matchMedia('(prefers-color-scheme: dark)')
  themeQuery.onchange = theme === 'system' ? apply : null
}

/* --- motion ------------------------------------------------------------- */

/** A duration token from finnest.css in milliseconds: 0 under reduced motion, because the design
    system's own stylesheet zeroes every duration there. Never a number typed into a component. */
export function durationMs(token: string): number {
  const raw = getComputedStyle(document.documentElement).getPropertyValue(`--fn-duration-${token}`).trim()
  return parseDuration(raw)
}

/**
 * A CSS time in milliseconds, whatever its unit. The production build minifies the tokens
 * (`200ms` ships as `.2s`), and reading that with a bare parseFloat gave 0.2 "ms": every exit
 * (drawer, command palette, scrim, toast) was cut after a fifth of a millisecond, so nothing on
 * the live console ever animated out.
 */
export function parseDuration(raw: string): number {
  const match = /^(-?[\d.]+)(ms|s)?$/.exec(raw.trim())
  if (!match) return 0
  const value = parseFloat(match[1]!)
  if (!Number.isFinite(value)) return 0
  return match[2] === 's' ? value * 1000 : value
}

/**
 * Close with an exit animation: mark the element as leaving, wait `--fn-duration-exit`, then
 * really close. Under reduced motion the wait is zero and this is a plain close.
 */
export function useLeave(onClose: () => void): [boolean, () => void] {
  const [leaving, setLeaving] = useState(false)
  const latest = useRef(onClose)
  latest.current = onClose
  const close = () => {
    if (leaving) return
    const wait = durationMs('exit')
    if (wait <= 0) return latest.current()
    setLeaving(true)
    setTimeout(() => latest.current(), wait)
  }
  return [leaving, close]
}

/* --- toasts ------------------------------------------------------------- */

export interface Toast {
  id: number
  kind: 'error' | 'info' | 'good'
  text: string
  /** Set for the last `--fn-duration-exit` of its life, so it can leave rather than vanish. */
  leaving?: boolean
}

let nextId = 1
const listeners = new Set<(toasts: Toast[]) => void>()
let toasts: Toast[] = []

const publish = () => listeners.forEach((listener) => listener([...toasts]))

export function toast(text: string, kind: Toast['kind'] = 'info'): void {
  const item = { id: nextId++, kind, text }
  toasts = [...toasts, item].slice(-4)
  publish()
  const life = kind === 'error' ? 8000 : 4000
  const exit = durationMs('exit')
  setTimeout(() => {
    toasts = toasts.map((t) => (t.id === item.id ? { ...t, leaving: true } : t))
    publish()
  }, life - exit)
  setTimeout(() => {
    toasts = toasts.filter((t) => t.id !== item.id)
    publish()
  }, life)
}

export function useToasts(): Toast[] {
  const [current, setCurrent] = useState<Toast[]>(toasts)
  useEffect(() => {
    listeners.add(setCurrent)
    return () => {
      listeners.delete(setCurrent)
    }
  }, [])
  return current
}

/* --- no counting up from zero ---------------------------------------------

 * An earlier version counted the headline figures up from zero over 450 ms. It looked good and it
 * was wrong: a screenshot taken mid-animation showed "value protected" at 13.15 lakh when the
 * answer is 19.37, and the catch-rate tile read 34.7% while the matrix two panels below read
 * 51.2%. A console whose whole argument is that a number must carry its denominator and its
 * provenance cannot put a number on screen that is not the number.
 *
 * The figures do roll now (components/Rolling.tsx), but never through a false value: on first
 * paint each digit of the *final* figure rises into its slot, and on a later change only the
 * digits that changed roll, old to new, like the app's RollingAmount. No frame shows a number the
 * data does not say.
 */

/** A clock that ticks, so "12s ago" is 12 seconds ago rather than whenever the row last rendered. */
export function useNow(everyMs = 1000): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), everyMs)
    return () => clearInterval(timer)
  }, [everyMs])
  return now
}

/**
 * Run `tick` on an interval, but only while the tab is visible and the caller wants it.
 *
 * A console left open on a second monitor overnight should not keep reading Firestore. This is
 * also the reason polling is safe here at all: the audit trail is a database read, not a Gemini
 * route - those are never put on a timer.
 *
 * `tick` is held in a ref and deliberately kept out of the effect's dependencies. It used to be in
 * them, and the one caller that matters renders every second from its own clock, so the interval
 * was torn down and rebuilt a second after it started and never once reached five. The poll had
 * never fired: rows only refreshed on focus and nothing was ever marked new. An interval whose
 * lifetime depends on an inline callback is an interval that restarts on every render, so the ref
 * is not an optimisation here - it is the difference between polling and not.
 */
export function usePoll(tick: () => void, everyMs: number, enabled: boolean): void {
  const latest = useRef(tick)
  latest.current = tick

  useEffect(() => {
    if (!enabled) return
    const run = () => {
      if (document.visibilityState === 'visible') latest.current()
    }
    const timer = window.setInterval(run, everyMs)
    document.addEventListener('visibilitychange', run)
    return () => {
      clearInterval(timer)
      document.removeEventListener('visibilitychange', run)
    }
  }, [enabled, everyMs])
}
