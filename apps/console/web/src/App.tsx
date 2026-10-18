/**
 * The console.
 *
 * Signed out: a login screen. Signed in: a shell with six views, a command palette and a drawer.
 * Everything else lives in a component; this file only decides what is on screen and wires the
 * keyboard to it.
 */

import { useCallback, useEffect, useState } from 'react'
import { ApiError, getOverview } from './lib/api'
import { clearSession, session as readSession, type Session } from './lib/auth'
import type { Overview } from './lib/types'
import { DENSITIES, PRESETS, THEMES, toast, useHashView, usePref, type Density, type Preset, type Theme, type ViewId } from './lib/ui'
import { LangContext, useT, type Lang } from './lib/i18n'
import { setFormatLang } from './lib/format'
import { Icon } from './components/Wordmark'
import { AccountDrawer } from './components/AccountDrawer'
import { CommandPalette, type Command } from './components/CommandPalette'
import { Login } from './components/Login'
import { LivePanel } from './components/LivePanel'
import { Shell } from './components/Shell'
import { ShortcutHelp } from './components/ShortcutHelp'
import { Toasts } from './components/Toasts'
import { AccountsView } from './components/views/AccountsView'
import { CampaignsView } from './components/views/CampaignsView'
import { CasesView } from './components/views/CasesView'
import { CashoutView } from './components/views/CashoutView'
import { SystemView } from './components/views/SystemView'
import { LogsView } from './components/views/LogsView'
import { SettingsView } from './components/views/SettingsView'
import { GatesView, ModelsView, OverviewView, RiskView } from './components/views/Views'

const LANGS: readonly Lang[] = ['bn', 'en']

const JUMP: Record<string, ViewId> = {
  o: 'overview', g: 'gates', r: 'risk', a: 'accounts', u: 'logs', c: 'cases', i: 'campaigns', t: 'cashout', m: 'models', l: 'live', s: 'settings',
}

export default function App() {
  /* Bangla is the default and English the parallel (design system, "Voice and tone"). The
     storage keys keep their pre-rename names so nobody's preferences or session are lost. */
  const [lang, setLang] = usePref<Lang>('bhorosha-admin-lang', 'bn', LANGS)
  setFormatLang(lang)
  return (
    <LangContext.Provider value={lang}>
      <Console lang={lang} setLang={setLang} />
    </LangContext.Provider>
  )
}

function Console({ lang, setLang }: { lang: Lang; setLang: (value: Lang) => void }) {
  const { t } = useT()
  const [session, setSession] = useState<Session | null>(readSession)
  const [overview, setOverview] = useState<Overview | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [refreshing, setRefreshing] = useState(false)
  const [account, setAccount] = useState<string | null>(null)
  /* Clicking a bar on the typology chart filters the accounts list: a chart in an operations
     console should be a filter you can see, not a picture you can only look at. */
  const [typology, setTypology] = useState<string | null>(null)
  const [palette, setPalette] = useState(false)
  const [help, setHelp] = useState(false)
  const [view, go] = useHashView()
  const [theme, setTheme] = usePref<Theme>('bhorosha-admin-theme', 'system', THEMES)
  const [preset, setPreset] = usePref<Preset>('bhorosha-admin-preset', 'teal', PRESETS)
  const [density, setDensity] = usePref<Density>('bhorosha-admin-density', 'comfortable', DENSITIES)

  const load = useCallback(async (refresh = false) => {
    if (refresh) setRefreshing(true)
    try {
      setOverview(await getOverview(refresh))
      setError(null)
      if (refresh) toast(t('toast.rebuilt'), 'good')
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) return
      setError((err as Error).message)
      toast((err as Error).message, 'error')
    } finally {
      setRefreshing(false)
    }
  }, [t])

  useEffect(() => {
    if (session) void load()
  }, [load, session])

  // A 401 anywhere drops us back to the login screen rather than leaving a dead page behind.
  useEffect(() => {
    const onSignedOut = () => setSession(null)
    window.addEventListener('bhorosha-signed-out', onSignedOut)
    return () => window.removeEventListener('bhorosha-signed-out', onSignedOut)
  }, [])

  useEffect(() => {
    if (!session) return
    let pending = ''
    const onKey = (event: KeyboardEvent) => {
      const typing = ['INPUT', 'TEXTAREA'].includes((event.target as HTMLElement)?.tagName)
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault()
        setPalette(true)
        return
      }
      if (typing) return
      if (event.key === '?') setHelp(true)
      // The account drawer closes itself on Escape, so it can play its exit.
      if (event.key === 'Escape') setHelp(false)
      if (event.key === '/') {
        const search = document.querySelector<HTMLInputElement>('input.search')
        if (search) {
          event.preventDefault()
          search.focus()
        }
      }
      if (event.key === 'g') {
        pending = 'g'
        setTimeout(() => (pending = ''), 900)
        return
      }
      if (pending === 'g' && JUMP[event.key]) {
        go(JUMP[event.key]!)
        pending = ''
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [go, session])

  const pickTypology = (name: string) => {
    setTypology(name)
    go('accounts')
  }

  const signOut = () => {
    clearSession()
    setSession(null)
    setOverview(null)
  }

  if (!session) return <Login onSignedIn={setSession} lang={lang} setLang={setLang} theme={theme} setTheme={setTheme} />

  const extras: Command[] = [
    { id: 'cmd:refresh', label: t('palette.rebuild'), group: t('palette.actions'), run: () => void load(true) },
    { id: 'cmd:lang', label: `${t('palette.switchto')} ${lang === 'en' ? 'বাংলা' : 'English'}`, group: t('palette.actions'), run: () => setLang(lang === 'en' ? 'bn' : 'en') },
    ...(['system', 'light', 'dark'] as Theme[])
      .filter((option) => option !== theme)
      .map((option) => ({
        id: `cmd:theme:${option}`,
        label: `${t('palette.switchto')} ${t(`settings.${option}`)}`,
        group: t('palette.actions'),
        run: () => setTheme(option),
      })),
    ...PRESETS.filter((option) => option !== preset).map((option) => ({
      id: `cmd:preset:${option}`,
      label: `${t('settings.palette')}: ${t(`preset.${option}`)}`,
      group: t('palette.actions'),
      run: () => setPreset(option),
    })),
    { id: 'cmd:density', label: `${t('palette.switchto')} ${density === 'compact' ? t('settings.comfortable') : t('settings.compact')}`, group: t('palette.actions'), run: () => setDensity(density === 'compact' ? 'comfortable' : 'compact') },
    { id: 'cmd:help', label: t('palette.help'), group: t('palette.actions'), run: () => setHelp(true) },
    { id: 'cmd:signout', label: t('top.signout'), group: t('palette.actions'), run: signOut },
  ]

  return (
    <>
      <Shell
        view={view}
        go={go}
        username={session.username}
        overview={overview}
        onCommand={() => setPalette(true)}
        onSignOut={signOut}
        onRefresh={() => void load(true)}
        refreshing={refreshing}
        lang={lang}
        setLang={setLang}
        theme={theme}
        setTheme={setTheme}
        preset={preset}
        setPreset={setPreset}
      >
        {error && (
          <div className="note bad" role="alert">
            <Icon name="error" />
            <div>
              <b>{t('error.load')}</b> {error}
              <div>{t('error.next')}</div>
              <div className="dim">
                {t('error.running')} <code>tools/dev.sh</code>
              </div>
              <button className="sm" onClick={() => void load()}>
                <Icon name="refresh" />
                {t('action.retry')}
              </button>
            </div>
          </div>
        )}
        {!overview && !error && <Skeleton />}

        {overview && view === 'overview' && (
          <OverviewView overview={overview} onOpenAccount={setAccount} onPickTypology={pickTypology} />
        )}
        {overview && view === 'gates' && <GatesView overview={overview} />}
        {overview && view === 'risk' && <RiskView overview={overview} />}
        {overview && view === 'accounts' && (
          <AccountsView
            board={overview.mule_board}
            meta={overview.mule_board_meta}
            onOpen={setAccount}
            typology={typology}
            onClearTypology={() => setTypology(null)}
          />
        )}
        {view === 'logs' && <LogsView onOpenAccount={setAccount} />}
        {view === 'cases' && <CasesView onOpenAccount={setAccount} />}
        {view === 'campaigns' && <CampaignsView />}
        {view === 'cashout' && <CashoutView />}
        {overview && view === 'models' && <ModelsView overview={overview} onPickTypology={pickTypology} />}
        {view === 'live' && (
          <>
            <SystemView />
            <LivePanel onOpenAccount={setAccount} />
          </>
        )}
        {view === 'settings' && (
          <SettingsView
            session={session}
            overview={overview}
            theme={theme}
            setTheme={setTheme}
            preset={preset}
            setPreset={setPreset}
            density={density}
            setDensity={setDensity}
            lang={lang}
            setLang={setLang}
            onSignOut={signOut}
          />
        )}
      </Shell>

      {account && <AccountDrawer acctId={account} onClose={() => setAccount(null)} />}
      <CommandPalette
        open={palette}
        onClose={() => setPalette(false)}
        go={go}
        board={overview?.mule_board ?? []}
        openAccount={setAccount}
        extras={extras}
      />
      {help && <ShortcutHelp onClose={() => setHelp(false)} />}
      <Toasts />
    </>
  )
}

function Skeleton() {
  return (
    <div className="skeleton" aria-busy="true">
      <div className="grid g-4">
        {[0, 1, 2, 3].map((index) => (
          <div key={index} className="skel-tile" />
        ))}
      </div>
      <div className="skel-panel" />
      <div className="skel-panel" />
    </div>
  )
}
