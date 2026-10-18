/**
 * Formatting rules the whole console obeys.
 *
 * Digits follow the language, as the design system requires everywhere (README section 3,
 * "Numbers and money"): Bangla digits in Bangla, Latin digits in English, lakh grouping always,
 * `৳` + space + amount. Identifiers (account ids, gate ids, model versions) are not numbers and
 * are never converted. Asia/Dhaka on every timestamp, with the offset printed, because an analyst
 * reading an audit trail in the wrong timezone reaches the wrong conclusion about what happened
 * first.
 *
 * The language is module state rather than an argument: App sets it on every render before any
 * child formats a figure, so the hundred-odd call sites did not each have to grow a parameter.
 */

export const DHAKA = 'Asia/Dhaka'

let current: 'en' | 'bn' = 'bn'
export const setFormatLang = (lang: 'en' | 'bn'): void => {
  current = lang
}

/** Bangla digits when the console is in Bangla. Commas, dots and signs pass through. */
export const digits = (value: string, lang: 'en' | 'bn' = current): string =>
  lang === 'bn' ? value.replace(/[0-9]/g, (digit) => '০১২৩৪৫৬৭৮৯'[Number(digit)]!) : value

/** Bangladeshi grouping: 12,34,567 rather than 1,234,567. */
export const n = (value: number | null | undefined): string =>
  value === null || value === undefined || Number.isNaN(value) ? '—' : digits(value.toLocaleString('en-IN'))

/** `value.toFixed(places)` in the active digits: probabilities, scores, thresholds. */
export const fx = (value: number | null | undefined, places: number): string =>
  value === null || value === undefined || Number.isNaN(value) ? '—' : digits(value.toFixed(places))

export const taka = (value: number | null | undefined, lang: 'en' | 'bn' = current): string => {
  if (value === null || value === undefined) return '—'
  if (Math.abs(value) >= 100000)
    return `৳ ${digits((value / 100000).toFixed(2), lang)} ${lang === 'bn' ? 'লাখ' : 'lakh'}`
  return `৳ ${digits(Math.round(value).toLocaleString('en-IN'), lang)}`
}

/** A share, rendered as a percentage. Never call this without rendering its denominator too. */
export const pct = (value: number | null | undefined, places = 1): string =>
  value === null || value === undefined ? '—' : `${digits((value * 100).toFixed(places))}%`

export const ratio = (part: number, whole: number, places = 1): string =>
  whole === 0 ? '—' : `${digits(((100 * part) / whole).toFixed(places))}%`

export const dhakaTime = (iso: string): string =>
  digits(new Date(iso).toLocaleString('en-GB', { timeZone: DHAKA, hour12: false }) + ' +06')

export const dhakaDate = (iso: string): string =>
  digits(new Date(iso).toLocaleDateString('en-GB', { timeZone: DHAKA, day: '2-digit', month: 'short' }))

export const ago = (iso: string, lang: 'en' | 'bn' = current): string => digits(agoLatin(iso, lang), lang)

const agoLatin = (iso: string, lang: 'en' | 'bn'): string => {
  const seconds = (Date.now() - new Date(iso).getTime()) / 1000
  const [s_, m_, h_, d_] = lang === 'bn' ? ['সে', 'মি', 'ঘ', 'দিন'] : ['s', 'm', 'h', 'd']
  const suffix = lang === 'bn' ? ' আগে' : ' ago'
  if (seconds < 90) return `${Math.round(seconds)}${s_}${suffix}`
  if (seconds < 5400) return `${Math.round(seconds / 60)}${m_}${suffix}`
  if (seconds < 172800) return `${Math.round(seconds / 3600)}${h_}${suffix}`
  return `${Math.round(seconds / 86400)}${d_}${suffix}`
}

/**
 * Severity tone for a decision, a band or a verdict. Never the only encoding — always with a label.
 *
 * The ramp is the design system's (README section 2, "Status"): good = success (safe, done),
 * info = info (neutral facts), warn = warning (step-up, delay, pending), high = the warning *fill*
 * (a hold: still amber, never red, but heavier than a delay), bad = danger (block, critical, a
 * failing check; the only red). muted = neutral (released, no data).
 */
export const tone = (key: string): string =>
  ({
    allow: 'good', step_up: 'warn', delay: 'warn', hold: 'high', block: 'bad',
    low: 'good', medium: 'warn', high: 'high', critical: 'bad',
    MODEL: 'good', RULE: 'info', STUB: 'warn', OFF: 'bad', NONE: 'muted', 'NO DATA': 'muted',
    /* Provenance. SYNTHETIC is "simulated", which the design system gives to amber; LIVE is not a
       status at all, so it takes the brand container rather than a status colour. */
    SYNTHETIC: 'warn', LIVE: 'brand',
  })[key] ?? 'info'

/**
 * "2m 14s ago", to the second.
 *
 * The audit log is read while things are happening, and "2m ago" is the same string for anything
 * between two and three minutes - which is exactly the resolution an operator watching a demo
 * does not have. Seconds are cheap; vagueness is not.
 */
export const agoPrecise = (iso: string, lang: 'en' | 'bn' = current, now = Date.now()): string =>
  digits(agoPreciseLatin(iso, lang, now), lang)

const agoPreciseLatin = (iso: string, lang: 'en' | 'bn', now: number): string => {
  const seconds = Math.max(0, Math.round((now - new Date(iso).getTime()) / 1000))
  const bn = lang === 'bn'
  const suffix = bn ? ' আগে' : ' ago'
  if (seconds < 60) return `${seconds}${bn ? 'সে' : 's'}${suffix}`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}${bn ? 'মি' : 'm'} ${seconds % 60}${bn ? 'সে' : 's'}${suffix}`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}${bn ? 'ঘ' : 'h'} ${minutes % 60}${bn ? 'মি' : 'm'}${suffix}`
  return `${Math.floor(hours / 24)}${bn ? 'দিন' : 'd'} ${hours % 24}${bn ? 'ঘ' : 'h'}${suffix}`
}
