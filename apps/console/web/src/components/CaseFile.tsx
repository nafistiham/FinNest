/**
 * A Case Zero case file, as an analyst reads it.
 *
 * The watch-list row says three sentences about one account. The case behind it holds much more: the decision and
 * who made which part of it (code's minimum from the mule score, the investigator's proposal), every account with its
 * role and the tool calls that prove it, the red flags, the timeline, the look-alikes it ruled out, both narratives,
 * the model's reasons, the checks code ran and what the run cost. The same view serves a live case and the recorded
 * run, so the demo can show a full file without calling Gemini.
 */

import type { Bilingual, CaseCite, CaseFile } from '../lib/types'
import { digits, fx, n } from '../lib/format'
import { useT } from '../lib/i18n'
import { Icon } from './Wordmark'
import { Chip, Tile } from './primitives'

const ACTION_TONE: Record<string, string> = { freeze: 'bad', edd: 'warn', monitor: 'warn', close_no_action: 'muted' }
const STATUS_TONE: Record<string, string> = { done: 'good', degraded: 'warn', failed: 'bad' }
const BAND_TONE: Record<string, string> = { critical: 'bad', high: 'warn', medium: 'warn', low: 'muted' }

export function CaseFileView({ file, onOpenAccount }: { file: CaseFile; onOpenAccount?: (acctId: string) => void }) {
  const { t, lang } = useT()
  const say = (text: Bilingual | null | undefined, fallback = '—') => (text ? (lang === 'bn' ? text.bn : text.en) : fallback)
  const when = (ts: string | null | undefined) => (ts ? digits(ts.replace('T', ' ').slice(0, 16), lang) : '—')
  const d = file.decision
  const otherNarrative = lang === 'bn' ? file.narrative.en : file.narrative.bn

  const cites = (list: CaseCite[]) => (
    <span className="cites">
      {list.map((c) => (
        <span className="cite mono" key={c.call_id}>
          {c.call_id}
          {c.tool ? ` · ${c.tool}` : ''}
        </span>
      ))}
    </span>
  )
  const account = (id: string) =>
    onOpenAccount && id.startsWith('acct_') ? (
      <button className="sm mono" onClick={() => onOpenAccount(id)}>
        {id}
      </button>
    ) : (
      <span className="mono">{id}</span>
    )

  return (
    <div className="casefile">
      <div className="toolbar">
        <Chip kind={file.source === 'live' ? 'info' : 'violet'}>
          <Icon name={file.source === 'live' ? 'sensors' : 'restart_alt'} />
          {t(file.source === 'live' ? 'casefile.live' : 'casefile.recorded')}
        </Chip>
        <Chip kind={STATUS_TONE[file.status ?? ''] ?? 'info'}>
          <Icon name={file.status === 'done' ? 'check_circle' : 'error'} />
          {t(`casefile.status.${file.status ?? 'unknown'}`)}
        </Chip>
        <span className="mono">{file.case_id}</span>
        <span className="dim">
          {t('casefile.seed')} <span className="mono">{file.seed ?? '—'}</span> · {t('casefile.asof')} {when(file.as_of)}
        </span>
      </div>

      <div className="grid g-4 gap-bottom">
        <Tile
          label={t('casefile.action')}
          value={<Chip kind={ACTION_TONE[d.action ?? ''] ?? 'info'}>{say(d.action_label)}</Chip>}
          sub={`${t('casefile.floor')}: ${say(d.floor_action_label)}`}
          badge="RULE"
          small
        />
        <Tile
          label={t('casefile.score')}
          value={d.model_score == null ? '—' : fx(d.model_score, 4)}
          sub={d.band ? <Chip kind={BAND_TONE[d.band] ?? 'info'}>{t(`band.${d.band}`)}</Chip> : undefined}
          badge="MODEL"
        />
        <Tile
          label={t('casefile.proposed')}
          value={say(d.proposed_action_label)}
          sub={t(d.escalated ? 'casefile.escalated' : 'casefile.not_escalated')}
          badge="MODEL"
          small
        />
        <Tile label={t('casefile.typology')} value={say(file.typology_label)} sub={<span className="mono">{file.typology ?? ''}</span>} badge="MODEL" small />
      </div>

      <h3 className="case-h">{t('casefile.narrative')}</h3>
      <p className="case-narrative" lang={lang}>
        {say(file.narrative, '—') || '—'}
      </p>
      {otherNarrative && (
        <details className="explainer">
          <summary>{t('casefile.narrative.other')}</summary>
          <p className="case-narrative" lang={lang === 'bn' ? 'en' : 'bn'}>
            {otherNarrative}
          </p>
        </details>
      )}

      <h3 className="case-h">
        {t('casefile.members')} ({n(file.members.length)})
      </h3>
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>{t('accounts.account')}</th>
              <th>{t('accounts.role')}</th>
              <th>{t('casefile.col.evidence')}</th>
            </tr>
          </thead>
          <tbody>
            {file.members.map((m) => (
              <tr key={m.acct_id}>
                <td>{account(m.acct_id)}</td>
                <td>
                  <Chip kind={m.role === 'victim' ? 'info' : 'violet'}>{say(m.role_label, m.role)}</Chip>
                </td>
                <td>{cites(m.evidence)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <h3 className="case-h">
        {t('casefile.flags')} ({n(file.red_flags.length)})
      </h3>
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>{t('casefile.col.flag')}</th>
              <th>{t('casefile.col.wrote')}</th>
              <th>{t('casefile.col.evidence')}</th>
            </tr>
          </thead>
          <tbody>
            {file.red_flags.map((f, i) => (
              <tr key={`${f.code}-${i}`}>
                <td>
                  <Chip kind="warn">{f.code}</Chip>
                  <div className="dim">{say(f.meaning, '')}</div>
                </td>
                <td>{f.text}</td>
                <td>{cites(f.evidence)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {file.timeline.length > 0 && (
        <>
          <h3 className="case-h">{t('casefile.timeline')}</h3>
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>{t('casefile.col.time')}</th>
                  <th>{t('casefile.col.event')}</th>
                  <th>{t('casefile.col.evidence')}</th>
                </tr>
              </thead>
              <tbody>
                {file.timeline.map((e, i) => (
                  <tr key={`${e.ts}-${i}`}>
                    <td className="mono">{when(e.ts)}</td>
                    <td>{e.text}</td>
                    <td>{cites(e.evidence)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}

      {file.excluded.length > 0 && (
        <>
          <h3 className="case-h">
            {t('casefile.excluded')} ({n(file.excluded.length)})
          </h3>
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>{t('accounts.account')}</th>
                  <th>{t('casefile.col.reason')}</th>
                  <th>{t('casefile.col.evidence')}</th>
                </tr>
              </thead>
              <tbody>
                {file.excluded.map((x) => (
                  <tr key={x.acct_id}>
                    <td>{account(x.acct_id)}</td>
                    <td>{x.reason}</td>
                    <td>{cites(x.evidence)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}

      {file.model_reasons.length > 0 && (
        <>
          <h3 className="case-h">{t('casefile.reasons')}</h3>
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>{t('casefile.col.feature')}</th>
                  <th className="num">{t('casefile.col.value')}</th>
                  <th className="num">{t('casefile.col.contribution')}</th>
                </tr>
              </thead>
              <tbody>
                {file.model_reasons.slice(0, 6).map((r) => (
                  <tr key={r.feature}>
                    <td className="mono">{r.feature}</td>
                    <td className="num">{r.value == null ? '—' : fx(r.value, 3)}</td>
                    <td className="num">{r.contribution == null ? '—' : `${r.direction === 'down' ? '−' : '+'}${fx(Math.abs(r.contribution), 2)}`}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}

      <h3 className="case-h">{t('casefile.checks')}</h3>
      <ul className="facts">
        <li>
          {file.checks.citations_passed_first_time ? t('casefile.check.citations.ok') : t('casefile.check.citations.retry')}
        </li>
        <li>
          {t('casefile.check.kept')}: {n(file.checks.members_kept)}
          {file.checks.moved_to_excluded.length > 0 &&
            ` · ${t('casefile.check.moved')}: ${file.checks.moved_to_excluded.join(', ')}`}
        </li>
        <li>
          {t('casefile.check.flags')}: {n(file.checks.flags_dropped.length)}
        </li>
      </ul>

      <h3 className="case-h">{t('casefile.run')}</h3>
      <div className="grid g-4 gap-bottom">
        <Tile label={t('casefile.run.calls')} value={n(file.run.tool_calls)} sub={file.run.model ?? ''} badge="MODEL" />
        <Tile label={t('casefile.run.turns')} value={n(file.run.turns)} sub={`${n(file.run.tokens_in)} / ${n(file.run.tokens_out)} ${t('casefile.run.tokens')}`} badge="MODEL" />
        <Tile label={t('casefile.run.cost')} value={file.run.cost_usd == null ? '—' : `US$ ${fx(file.run.cost_usd, 3)}`} badge="MODEL" />
        {/* A recorded run carries its wall clock; a live case only Gemini's own time. */}
        <Tile
          label={t(file.run.seconds == null ? 'casefile.run.llm_time' : 'casefile.run.time')}
          value={
            file.run.seconds != null
              ? `${fx(file.run.seconds, 1)} ${t('casefile.run.seconds')}`
              : file.run.llm_ms != null
                ? `${fx(file.run.llm_ms / 1000, 1)} ${t('casefile.run.seconds')}`
                : '—'
          }
          sub={
            file.run.seconds != null && file.run.llm_ms != null
              ? `${t('casefile.run.llm')}: ${fx(file.run.llm_ms / 1000, 1)} ${t('casefile.run.seconds')}`
              : undefined
          }
          badge="MODEL"
        />
      </div>

      {file.calls.length > 1 && (
        <details className="explainer">
          <summary>
            {t('casefile.path')} ({n(file.calls.length)})
          </summary>
          <div className="trace">
            {file.calls.map((c) => (
              <div className="step" key={c.call_id}>
                <span className="k">{c.call_id}</span> {c.tool ?? '—'} {JSON.stringify(c.args)}
              </div>
            ))}
          </div>
        </details>
      )}

      {file.limitations && (
        <div className="note">
          <Icon name="info" />
          <div>
            <b>{t('casefile.limitations')}</b> {file.limitations}
          </div>
        </div>
      )}
    </div>
  )
}
