/**
 * The way in.
 *
 * It says what the credentials are, because this is a demo account on a synthetic dataset and
 * pretending otherwise would be theatre. It also says what this sign-in is not, in the same place
 * an operator would look for a "forgot password" link.
 */

import { useState } from 'react'
import { Icon, Mark, Wordmark } from './Wordmark'
import { SignInError, signIn, type Session } from '../lib/auth'
import { useT, type Lang } from '../lib/i18n'
import type { Theme } from '../lib/ui'
import { Segmented } from './primitives'

export function Login({
  onSignedIn,
  lang,
  setLang,
  theme,
  setTheme,
}: {
  onSignedIn: (session: Session) => void
  lang: Lang
  setLang: (value: Lang) => void
  theme: Theme
  setTheme: (value: Theme) => void
}) {
  const { t } = useT()
  const [username, setUsername] = useState('admin')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    setBusy(true)
    setError(null)
    try {
      onSignedIn(await signIn(username, password))
    } catch (err) {
      setError(
        err instanceof SignInError
          ? err.status === 401
            ? t('login.wrong')
            : t('login.failed', { status: String(err.status) })
          : t('error.next'),
      )
      setBusy(false)
    }
  }

  return (
    <div className="login-page">
      <form className="login-card" onSubmit={submit}>
        <div className="login-top">
          {/* The lockup: mark above wordmark, left-aligned (README section 1). */}
          <div className="login-brand">
            <Mark px={88} />
            <Wordmark />
            <div className="login-sub">{t('app.name')}</div>
          </div>
          {/* Language and theme before signing in: a reader on a dark OS who wants light should not
              have to sign in first to get it. */}
          <div className="login-prefs">
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
          </div>
        </div>

        <p className="login-tagline">{t('app.tagline')}</p>
        <p className="login-lede">{t('app.lede')}</p>

        <label className="field">
          <span>{t('login.username')}</span>
          <input value={username} onChange={(e) => setUsername(e.target.value)} autoComplete="username" autoFocus />
        </label>
        <label className="field">
          <span>{t('login.password')}</span>
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="current-password"
          />
        </label>

        {error && (
          <div className="note bad" role="alert">
            <Icon name="error" />
            <span>{error}</span>
          </div>
        )}

        <button className="fn-button fn-button--block login-submit" disabled={busy || !password}>
          {busy ? t('login.checking') : t('login.submit')}
        </button>

        <div className="note info login-hint">
          <Icon name="info" />
          <div>
            <b>{t('login.demo')}</b> · <code>ADMIN_USER</code> · <code>ADMIN_PASSWORD</code>
            <div className="dim">{t('login.override')}</div>
          </div>
        </div>

        <p className="login-foot">{t('login.foot')}</p>
      </form>
    </div>
  )
}
