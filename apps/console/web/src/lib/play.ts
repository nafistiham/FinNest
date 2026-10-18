/**
 * One scenario turned into steps to play, from the engine's own answer.
 *
 * Nothing is invented here: the steps are built from what `evaluate()` concluded about each check.
 * Every check gets a step, including the ones that found nothing - a payment that passes cleanly
 * is six satisfied checks, and showing only the ones that fired made an ordinary payment look
 * like nothing had happened at all.
 */

import type { Scenario, ScenarioCheck } from './types'

export type Stage = 'send' | 'check' | 'merge' | 'write' | 'notify' | 'investigate' | 'answer'

export interface Step {
  stage: Stage
  /** The node or check to light while this step is on screen. */
  node: string
  /** The edge to light, as `from>to`. */
  edge?: string
  check?: ScenarioCheck
}

/** What each check reaches outside the service, so the picture shows where its answer came from. */
const USES: Record<string, string> = {
  scam: 'risk-mw>gemini',
  'mule-lgbm': 'risk-mw>artefacts',
  'ato-identity': 'risk-mw>artefacts',
  'app-safety': 'risk-mw>artefacts',
  ledger: 'risk-mw>ledger',
}

export function stepsFor(scenario: Scenario): Step[] {
  const steps: Step[] = [{ stage: 'send', node: 'app', edge: 'app>risk-mw' }]
  for (const check of scenario.checks) {
    steps.push({ stage: 'check', node: check.id, edge: USES[check.id], check })
  }
  steps.push({ stage: 'merge', node: 'rules' })
  steps.push({ stage: 'write', node: 'firestore', edge: 'risk-mw>firestore' })
  // A hold is the only decision that asks a second person.
  if (scenario.decision === 'hold') {
    steps.push({ stage: 'notify', node: 'trusted', edge: 'risk-mw>trusted' })
  }
  /* The investigator gets a step whenever it has something to do with this payment: either the
     payee is one it already named, or the model scored them high enough that a case would start
     from here. Both are worth seeing, and neither happens on its own. */
  if (scenario.watchlisted || scenario.checks.some((c) => c.id === 'mule-lgbm' && c.verdict === 'raised')) {
    steps.push({ stage: 'investigate', node: 'case-zero' })
  }
  steps.push({ stage: 'answer', node: 'app', edge: 'risk-mw>app' })
  return steps
}
