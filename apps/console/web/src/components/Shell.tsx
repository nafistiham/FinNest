/**
 * The frame: who you are, where you are, and how to get somewhere else.
 *
 * A sidebar rather than one long scroll. The console had grown to about five thousand pixels of
 * page, and an operator looking for the model health table should not have to remember how far
 * down it lives.
 */

import type { ReactNode } from 'react'
import { VIEWS, VIEW_GROUPS, type Preset, type Theme, type ViewId } from '../lib/ui'
import { useT, type Lang } from '../lib/i18n'
import { PresetPicker, Segmented } from './primitives'
import { Icon, Mark, Wordmark } from './Wordmark'
import type { Overview } from '../lib/types'
import { ago, dhakaTime, digits, n } from '../lib/format'

export function Shell({
  view,
  go,
  username,
  overview,
  onCommand,
  onSignOut,
  onRefresh,
  refreshing,
  lang,
  setLang,
  theme,
  setTheme,
  preset,
  setPreset,
  children,
}: {
  view: ViewId
  go: (id: ViewId) => void
  username: string
  overview: Overview | null
  onCommand: () => void
  onSignOut: () => void
  onRefresh: () => void
  refreshing: boolean
  lang: Lang
  setLang: (value: Lang) => void
  theme: Theme
  setTheme: (value: Theme) => void
  preset: Preset
  setPreset: (value: Preset) => void
  children: ReactNode
}) {
  const { t } = useT()
  const failing = overview?.policy.filter((check) => !check.ok).length ?? 0
  const counts: Partial<Record<ViewId, string>> = overview
    ? {
        gates: digits(`${overview.gates.filter((gate) => gate.badge !== 'NONE').length}/${overview.gates.length}`),
        accounts: n(overview.mule_board_meta.at_or_above_hold_threshold),
        models: n(overview.models.filter((model) => model.badge === 'MODEL').length),
      }
    : {}

  const item = (id: ViewId, variant: 'side' | 'tabs') => (
    <button
      key={id}
      className={`nav-item${view === id ? ' active' : ''}`}
      aria-current={view === id ? 'page' : undefined}
      onClick={() => go(id)}
      title={t(`view.${id}.hint`)}
    >
      <Icon name={ICONS[id]} filled={view === id} />
      <span className="nav-label">{t(`view.${id}`)}</span>
      {variant === 'side' && counts[id] && <span className="nav-count">{counts[id]}</span>}
      {id === 'overview' && failing > 0 && (
        <span className="nav-dot" title={`${n(failing)} ${t('top.failing')}`}>
          <Icon name="error" />
        </span>
      )}
    </button>
  )

  return (
    <div className="shell">
      <aside className="sidebar">
        {/* The lockup: the mark above the wordmark, left-aligned, with the product's own word
            beside it. The mark keeps its clear space through the padding around it. */}
        <div className="side-brand">
          <Mark px={40} />
          <div className="side-name">
            <Wordmark />
            <span className="side-sub">{t('app.sub')}</span>
          </div>
        </div>

        {/* Three groups, so nine views read as three jobs: watch, investigate, configure. */}
        <nav aria-label={t('top.menu')} className="side-nav">
          {VIEW_GROUPS.map((group) => (
            <div key={group.id} className="nav-group" role="group" aria-labelledby={`nav-${group.id}`}>
              <span className="nav-group-title" id={`nav-${group.id}`}>
                {t(`nav.${group.id}`)}
              </span>
              {group.views.map((id) => item(id, 'side'))}
            </div>
          ))}
        </nav>

        <div className="side-foot">
          <div className="side-controls" role="group" aria-label={t('nav.quick')}>
            <Segmented
              label={t('settings.language')}
              value={lang}
              onChange={setLang}
              options={[
                { value: 'bn', label: 'বাংলা' },
                { value: 'en', label: 'English' },
              ]}
            />
            <Segmented
              label={t('settings.theme')}
              value={theme}
              onChange={setTheme}
              options={[
                { value: 'system', label: t('settings.system'), icon: 'contrast' },
                { value: 'light', label: t('settings.light'), icon: 'light_mode' },
                { value: 'dark', label: t('settings.dark'), icon: 'dark_mode' },
              ]}
            />
            <PresetPicker value={preset} onChange={setPreset} variant="compact" />
          </div>
          <button className="nav-item" onClick={onCommand}>
            <Icon name="keyboard_command_key" />
            <span className="nav-label">{t('top.command')}</span>
            <kbd>⌘K</kbd>
          </button>
          <div className="side-user">
            <span className="avatar" aria-hidden="true">{username.slice(0, 1).toUpperCase()}</span>
            <div className="side-who">
              <b>{username}</b>
              <span>{t('top.operator')}</span>
            </div>
            <button className="sm ghost" onClick={onSignOut}>
              <Icon name="logout" />
              {t('top.signout')}
            </button>
          </div>
        </div>
      </aside>

      <div className="content">
        <header className="topbar">
          {/* Below 900 px the sidebar folds away; the brand and the views move up here. */}
          <div className="top-brand">
            <Mark px={32} />
            <span className="top-name">{t('app.name')}</span>
          </div>
          <div className="crumbs">
            <h1>{t(`view.${view}`)}</h1>
            <span>{t(`view.${view}.hint`)}</span>
          </div>
          <span className="spacer" />
          {overview && (
            <div className="top-meta">
              <span className="chip t-warn" title={t('top.synthetic.title')}>
                <Icon name="warning" />
                {t('badge.SYNTHETIC')}
              </span>
              <span className="dim top-window" title={`${t('top.built.title')} ${dhakaTime(overview.generated_at)}`}>
                {dhakaDateRange(overview.window.from, overview.window.to)} · {t('top.built')} {ago(overview.generated_at, lang)}
              </span>
            </div>
          )}
          <button className="sm ghost" onClick={onRefresh} disabled={refreshing} title={t('top.rebuild.title')}>
            <Icon name="refresh" />
            {refreshing ? t('top.rebuilding') : t('top.rebuild')}
          </button>
          <nav className="tabs" aria-label={t('top.menu')}>
            {VIEWS.map((view) => item(view.id, 'tabs'))}
          </nav>
        </header>
        {/* Keyed by view, so every view change replays the staggered entrance. */}
        <main key={view}>{children}</main>
      </div>
    </div>
  )
}

const ICONS = Object.fromEntries(VIEWS.map((view) => [view.id, view.icon])) as Record<ViewId, string>

/** The data window, in the active digits. The dates are ISO days; only their digits change. */
const dhakaDateRange = (from: string, to: string): string => digits(`${from} → ${to}`)
