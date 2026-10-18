/**
 * The riskiest accounts, as a working surface rather than a leaderboard.
 *
 * Search, a probability floor, role filters and sortable columns, because the question an analyst
 * actually asks is never "show me the top 25" - it is "which mule_L1 accounts above 0.9 did we
 * score this week". Exports carry `synthetic` in the filename so a screenshot of a spreadsheet
 * cannot be mistaken for a real extract.
 */

import { useMemo, useState } from 'react'
import type { BoardMeta, BoardRow } from '../../lib/types'
import { digits, fx, n } from '../../lib/format'
import { Icon } from '../Wordmark'
import { Chip, Panel, Explainer } from '../primitives'
import { useT } from '../../lib/i18n'
import { Info } from '../Info'

type SortKey = 'probability' | 'acct' | 'role' | 'typology'

export function AccountsView({
  board,
  meta,
  onOpen,
  typology,
  onClearTypology,
}: {
  board: BoardRow[]
  meta: BoardMeta
  onOpen: (acctId: string) => void
  /** Set when the operator clicked a bar on the typology chart. */
  typology: string | null
  onClearTypology: () => void
}) {
  const { t } = useT()
  const [query, setQuery] = useState('')
  const [floor, setFloor] = useState(0)
  const [role, setRole] = useState<string | null>(null)
  const [sort, setSort] = useState<SortKey>('probability')
  const [ascending, setAscending] = useState(false)

  const roles = useMemo(
    () => [...new Set(board.map((row) => row.role).filter((value): value is string => Boolean(value)))].sort(),
    [board],
  )

  const rows = useMemo(() => {
    const needle = query.trim().toLowerCase()
    const filtered = board.filter(
      (row) =>
        row.probability >= floor &&
        (!role || row.role === role) &&
        (!typology || row.typology === typology) &&
        (!needle ||
          row.acct.toLowerCase().includes(needle) ||
          (row.typology ?? '').toLowerCase().includes(needle) ||
          (row.ring ?? '').toLowerCase().includes(needle) ||
          row.shap.some((item) => item.feature.toLowerCase().includes(needle))),
    )
    const direction = ascending ? 1 : -1
    return [...filtered].sort((a, b) => {
      if (sort === 'probability') return direction * (a.probability - b.probability)
      const left = String(a[sort] ?? '')
      const right = String(b[sort] ?? '')
      return direction * left.localeCompare(right)
    })
  }, [ascending, board, floor, query, role, sort, typology])

  const download = () => {
    const header = 'acct,probability,role,typology,ring\n'
    const body = rows
      .map((row) => [row.acct, row.probability, row.role ?? '', row.typology ?? '', row.ring ?? ''].join(','))
      .join('\n')
    const blob = new Blob([header + body], { type: 'text/csv' })
    const link = document.createElement('a')
    link.href = URL.createObjectURL(blob)
    link.download = `finnest-synthetic-accounts-${new Date().toISOString().slice(0, 10)}.csv`
    link.click()
    URL.revokeObjectURL(link.href)
  }

  const header = (key: SortKey, label: string, numeric = false) => (
    <th
      className={`sortable${numeric ? ' num' : ''}${sort === key ? ' sorted' : ''}`}
      onClick={() => {
        if (sort === key) setAscending(!ascending)
        else {
          setSort(key)
          setAscending(false)
        }
      }}
    >
      {label} {sort === key ? (ascending ? '▲' : '▼') : ''}
    </th>
  )

  const maxContribution = Math.max(...board.flatMap((row) => row.shap.map((s) => Math.abs(s.contribution))), 1)

  return (
    <Panel
      title={t('accounts.title')}
      question={t('accounts.q')}
      badge={meta.badge}
      info="mule"
      right={
        <span className="chip t-muted">
          {n(rows.length)} / {n(board.length)} {t('accounts.shown')} · {n(meta.at_or_above_hold_threshold)} /{' '}
          {n(meta.scored)} {t('accounts.scored_at')} ≥ {digits(String(meta.hold_threshold))}
        </span>
      }
    >
      <div className="toolbar">
        <input
          className="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t('accounts.search')}
        />
        <label className="slider-field">
          <span>p(mule) ≥ {fx(floor, 2)}</span>
          <input type="range" min={0} max={1} step={0.05} value={floor} onChange={(e) => setFloor(Number(e.target.value))} />
        </label>
        <button className={`sm${floor >= meta.hold_threshold ? ' on' : ''}`} onClick={() => setFloor(floor >= meta.hold_threshold ? 0 : meta.hold_threshold)}>
          {t('accounts.threshold')}
        </button>
        <span className="spacer" />
        <button className="sm" onClick={download}>
          <Icon name="download" />
          CSV
        </button>
      </div>

      {typology && (
        <div className="toolbar">
          <span className="chip t-brand">
            {t('accounts.typology')}: {typology}
          </span>
          <button className="sm" onClick={onClearTypology}>
            <Icon name="close" />
            {t('palette.close')}
          </button>
        </div>
      )}

      <div className="toolbar">
        <button className={`sm${role === null ? ' on' : ''}`} onClick={() => setRole(null)}>
          {t('accounts.allroles')}
        </button>
        {roles.map((item) => (
          <button key={item} className={`sm${role === item ? ' on' : ''}`} onClick={() => setRole(role === item ? null : item)}>
            {item}
          </button>
        ))}
      </div>

      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              {header('acct', t('accounts.account'))}
              {header('probability', 'p(mule)', true)}
              {header('role', t('accounts.role'))}
              {header('typology', t('accounts.typology'))}
              <th>
                {t('accounts.contrib')} <Info k="shap" />
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.acct} className="clickable" onClick={() => onOpen(row.acct)}>
                <td className="mono">{row.acct}</td>
                <td className="num">
                  <Chip kind={row.probability >= 0.95 ? 'bad' : row.probability >= meta.hold_threshold ? 'high' : 'warn'}>
                    {fx(row.probability, 3)}
                  </Chip>
                </td>
                <td>{row.role ? <Chip kind="violet">{row.role}</Chip> : <span className="dim">—</span>}</td>
                <td className="mono dim">{row.typology ?? '—'}</td>
                <td>
                  {row.shap.map((item) => (
                    <div key={item.feature} className="shap-row">
                      <span className="mono dim" title={item.feature}>{item.feature}</span>
                      <div className="bar">
                        <i
                          style={{
                            width: `${Math.min(100, (100 * Math.abs(item.contribution)) / maxContribution)}%`,
                            background: item.direction === 'up' ? 'var(--bad-fill)' : 'var(--good-fill)',
                          }}
                        />
                      </div>
                      <span className="mono num">
                        {item.contribution > 0 ? '+' : item.contribution < 0 ? '−' : ''}
                        {digits(String(Math.abs(item.contribution)))}
                      </span>
                    </div>
                  ))}
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={5} className="empty">
                  <Icon name="person_search" />
                  <p>{t('accounts.none')}</p>
                  <button
                    className="sm"
                    onClick={() => {
                      setQuery('')
                      setFloor(0)
                      setRole(null)
                      onClearTypology()
                    }}
                  >
                    {t('accounts.clear')}
                  </button>
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      <Explainer>
        <code>{meta.model_version}</code> · {t('accounts.note')}
      </Explainer>
    </Panel>
  )
}
