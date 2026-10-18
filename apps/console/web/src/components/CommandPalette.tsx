/**
 * ⌘K.
 *
 * Six views, a few hundred accounts and a handful of toggles: enough that hunting for them with a
 * mouse is slower than typing. Account ids are matched directly, so pasting one from a Linear
 * comment and pressing enter opens it.
 */

import { useEffect, useMemo, useRef, useState } from 'react'
import type { BoardRow } from '../lib/types'
import { VIEWS, durationMs, type ViewId } from '../lib/ui'
import { useT } from '../lib/i18n'
import { fx } from '../lib/format'


export interface Command {
  id: string
  label: string
  hint?: string
  group: string
  run: () => void
}

export function CommandPalette({
  open,
  onClose,
  go,
  board,
  openAccount,
  extras,
}: {
  open: boolean
  onClose: () => void
  go: (id: ViewId) => void
  board: BoardRow[]
  openAccount: (acctId: string) => void
  extras: Command[]
}) {
  const { t } = useT()
  const [query, setQuery] = useState('')
  const [index, setIndex] = useState(0)
  const inputRef = useRef<HTMLInputElement>(null)

  /* Stay mounted for one `exit` beat after closing, so the palette leaves instead of vanishing
     (the open state lives in App, which unmounts nothing itself). */
  const [shown, setShown] = useState(open)
  const [leaving, setLeaving] = useState(false)
  useEffect(() => {
    if (open) {
      setShown(true)
      setLeaving(false)
      return
    }
    const wait = durationMs('exit')
    if (wait <= 0) {
      setShown(false)
      return
    }
    setLeaving(true)
    const timer = window.setTimeout(() => {
      setShown(false)
      setLeaving(false)
    }, wait)
    return () => window.clearTimeout(timer)
  }, [open])

  useEffect(() => {
    if (open) {
      setQuery('')
      setIndex(0)
      setTimeout(() => inputRef.current?.focus(), 10)
    }
  }, [open])

  const commands = useMemo<Command[]>(() => {
    const views: Command[] = VIEWS.map((view) => ({
      id: `view:${view.id}`,
      label: t(`view.${view.id}`),
      hint: t(`view.${view.id}.hint`),
      group: t('palette.goto'),
      run: () => go(view.id),
    }))
    const accounts: Command[] = board.slice(0, 25).map((row) => ({
      id: `acct:${row.acct}`,
      label: row.acct,
      hint: `p(mule) ${fx(row.probability, 3)}${row.role ? ` · ${row.role}` : ''}`,
      group: t('palette.openacct'),
      run: () => openAccount(row.acct),
    }))
    return [...views, ...extras, ...accounts]
  }, [board, extras, go, openAccount, t])

  const matches = useMemo(() => {
    const needle = query.trim().toLowerCase()
    if (!needle) return commands.slice(0, 12)
    const scored = commands.filter(
      (command) =>
        command.label.toLowerCase().includes(needle) || command.hint?.toLowerCase().includes(needle),
    )
    // An account id typed in full should win even if it is not on the board.
    if (scored.length === 0 && /^acct[_a-z0-9-]*$/i.test(needle)) {
      return [{ id: 'acct:raw', label: needle, hint: t('palette.openacct'), group: t('palette.openacct'), run: () => openAccount(needle) }]
    }
    return scored.slice(0, 12)
  }, [commands, openAccount, query, t])

  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
      if (event.key === 'ArrowDown') {
        event.preventDefault()
        setIndex((i) => Math.min(matches.length - 1, i + 1))
      }
      if (event.key === 'ArrowUp') {
        event.preventDefault()
        setIndex((i) => Math.max(0, i - 1))
      }
      if (event.key === 'Enter') {
        const chosen = matches[index]
        if (chosen) {
          chosen.run()
          onClose()
        }
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [index, matches, onClose, open])

  if (!shown) return null

  let lastGroup = ''
  return (
    <>
      <div className={`scrim${leaving ? ' leaving' : ''}`} onClick={onClose} />
      <div className={`palette${leaving ? ' leaving' : ''}`} role="dialog" aria-modal="true" aria-label={t('top.command')}>
        <input
          aria-label={t('palette.placeholder')}
          ref={inputRef}
          value={query}
          onChange={(event) => {
            setQuery(event.target.value)
            setIndex(0)
          }}
          placeholder={t('palette.placeholder')}
        />
        <div className="palette-list">
          {matches.length === 0 && <div className="palette-empty">{t('palette.nothing')}</div>}
          {matches.map((command, position) => {
            const header = command.group !== lastGroup ? command.group : null
            lastGroup = command.group
            return (
              <div key={command.id}>
                {header && <div className="palette-group">{header}</div>}
                <div
                  className={`palette-item${position === index ? ' active' : ''}`}
                  onMouseEnter={() => setIndex(position)}
                  onClick={() => {
                    command.run()
                    onClose()
                  }}
                >
                  <span>{command.label}</span>
                  {command.hint && <span className="hint">{command.hint}</span>}
                </div>
              </div>
            )
          })}
        </div>
        <div className="palette-foot">
          <kbd>↑</kbd> <kbd>↓</kbd> {t('palette.move')} · <kbd>↵</kbd> {t('palette.open')} · <kbd>esc</kbd>{' '}
          {t('palette.close')}
        </div>
      </div>
    </>
  )
}
