/**
 * What each kind of audit row is, in words, and what colour it gets.
 *
 * Since the design-system pass the stage colours avoid the status hues, which the design
 * system reserves for status: payment = info (a neutral fact), device = accent, call = neutral,
 * assistant = the brand container, action = warning (someone has to act: pending). Each chip
 * still carries its label, so colour is never the only signal.
 *
 * The raw kinds are route names - `scam_turn`, `apa_why_audio` - which tell an engineer where the
 * code is and an operations manager nothing. Each one gets a label that says what was being
 * checked.
 *
 * Colour groups by stage of the defence rather than by kind, because ten arbitrary colours is a
 * legend to memorise and five meaningful ones is a thing you learn once: blue is the payment
 * decision, violet is the device, orange is the live call, jade is the assistant talking to the customer,
 * gold is an action someone has to take.
 */

export interface EventKind {
  label: [string, string]
  tone: string
  group: string
}

export const EVENTS: Record<string, EventKind> = {
  score: { label: ['Payment decision', 'পেমেন্ট ডিসিশন'], tone: 'info', group: 'payment' },
  signals: { label: ['Device signals', 'ডিভাইস সিগন্যাল'], tone: 'violet', group: 'device' },
  appsafety: { label: ['App check', 'অ্যাপ চেক'], tone: 'violet', group: 'device' },
  scam_turn: { label: ['Call analysis', 'কল অ্যানালাইসিস'], tone: 'muted', group: 'call' },
  scam_live: { label: ['Live call', 'লাইভ কল'], tone: 'muted', group: 'call' },
  scam_transcribe: { label: ['Call transcript', 'কল ট্রান্সক্রিপ্ট'], tone: 'muted', group: 'call' },
  /* The route names are the wire, and the wire still says `apa_` because that is what the
     deployed service emits; renaming a key here would simply stop matching. What a reader sees is
     the assistant's name, which is FinNest Assistant. */
  intervene: { label: ['FinNest Assistant stepped in', 'ফিননেস্ট সহকারী এগিয়ে এসেছে'], tone: 'brand', group: 'assistant' },
  apa_turn: { label: ['Assistant chat', 'সহকারীর সাথে কথা'], tone: 'brand', group: 'assistant' },
  apa_why_audio: { label: ['Assistant voice', 'সহকারীর কণ্ঠ'], tone: 'brand', group: 'assistant' },
  // Live traffic carries `apa_why` and `trusted_contact_decision` and this map knew neither, so
  // the log showed an operations manager the raw route name - the one thing these labels exist to
  // avoid. A kind the service emits and this map does not know is a gap, not a new category.
  apa_why: { label: ['Assistant explains', 'সহকারী ব্যাখ্যা করছে'], tone: 'brand', group: 'assistant' },
  trusted_contact_create: { label: ['Trusted contact added', 'বিশ্বস্ত মানুষ যোগ'], tone: 'warn', group: 'action' },
  trusted_contact_decision: { label: ['Trusted contact answered', 'বিশ্বস্ত মানুষের সিদ্ধান্ত'], tone: 'warn', group: 'action' },
  investigate: { label: ['Investigation', 'তদন্ত'], tone: 'warn', group: 'action' },
}

export const eventOf = (kind: string): EventKind =>
  EVENTS[kind] ?? { label: [kind, kind], tone: 'muted', group: 'other' }

/**
 * The glyph beside an outcome.
 *
 * `allow` is the one that earns a tick: the payment went through and nobody was inconvenienced,
 * which on a page full of holds is the outcome worth being able to find at a glance.
 */
export const outcomeMark = (decision: string | null): { mark: string; tone: string } => {
  switch (decision) {
    case 'allow':
      return { mark: '✓', tone: 'good' }
    case 'step_up':
      return { mark: '◐', tone: 'warn' }
    case 'delay':
      return { mark: '⏱', tone: 'warn' }
    case 'hold':
      return { mark: '✋', tone: 'high' }
    case 'block':
      return { mark: '✕', tone: 'bad' }
    default:
      return { mark: '', tone: 'muted' }
  }
}
