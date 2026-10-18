/**
 * Are we stopping the right payments, and how are the scores spread?
 *
 * The matrix is four cells and a sentence. It is the most important thing on the page, because it
 * is the only view where a good outcome and a bad one sit next to each other at the same size.
 */

import type { Replay } from '../lib/types'
import { digits, n, pct } from '../lib/format'
import { Rolling } from './Rolling'
import { Panel, Spark, Explainer } from './primitives'
import { useT } from '../lib/i18n'

export function CatchVsFriction({ replay }: { replay: Replay }) {
  const { t } = useT()
  const { confusion, rates, histogram, histogram_edges } = replay
  const titles = histogram.map(
    (count, index) => `${digits(String(histogram_edges[index]))}–${digits(String(histogram_edges[index + 1]))}: ${n(count)} ${t('hist.payments')}`,
  )

  return (
    <div className="grid g-2">
      <Panel title={t('matrix.title')} question={t('matrix.q')} info="matrix">
        <div className="matrix">
          <div />
          <div className="head">{t('matrix.stopped')}</div>
          <div className="head">{t('matrix.through')}</div>

          <div className="side">{t('matrix.fraud')}</div>
          <div className="cell">
            <b className="t-text-good"><Rolling text={n(confusion.catch)} /></b>
            <span>{t('matrix.caught')}</span>
          </div>
          <div className="cell">
            <b className="t-text-bad"><Rolling text={n(confusion.miss)} /></b>
            <span>{t('matrix.escaped')}</span>
          </div>

          <div className="side">{t('matrix.genuine')}</div>
          <div className="cell">
            <b className="t-text-warn"><Rolling text={n(confusion.false_positive)} /></b>
            <span>{t('matrix.heldwrong')}</span>
          </div>
          <div className="cell">
            <b><Rolling text={n(confusion.true_negative)} /></b>
            <span>{t('matrix.fine')}</span>
          </div>
        </div>
        <Explainer>
          {t('matrix.sentence', {
            catch: n(confusion.catch),
            miss: n(confusion.miss),
            rate: pct(rates.catch_rate),
            genuine: n(rates.false_positive_rate_denominator),
            fp: n(confusion.false_positive),
            fpr: pct(rates.false_positive_rate, 2),
          })}{' '}
          <b>{t('matrix.never')}</b>
        </Explainer>
      </Panel>

      <Panel title={t('hist.title')} question={t('hist.q')} info="histogram">
        <Spark values={histogram} hotFrom={8} titles={titles} />
        <div className="axis">
          <span>{digits('0.0')}</span>
          <span>{digits('0.3')} {t('band.medium')}</span>
          <span>{digits('0.6')} {t('band.high')}</span>
          <span>{digits('0.85')} {t('band.critical')}</span>
          <span>{digits('1.0')}</span>
        </div>
        <p className="panel-note mono">
          {histogram
            .map((count, index) => (count ? `${digits(String(histogram_edges[index]))}:${n(count)}` : null))
            .filter(Boolean)
            .join('   ')}
        </p>
      </Panel>
    </div>
  )
}
