/** Preferences, the session, and the honest notes about what this sign-in is. */

import type { Overview } from '../../lib/types'
import { dhakaTime, fx } from '../../lib/format'
import { hoursLeft, type Session } from '../../lib/auth'
import { Panel, PresetPicker, Segmented, Tile } from '../primitives'
import type { Density, Preset, Theme } from '../../lib/ui'
import { useT, type Lang } from '../../lib/i18n'
import { Icon } from '../Wordmark'

export function SettingsView({
  session,
  overview,
  theme,
  setTheme,
  preset,
  setPreset,
  density,
  setDensity,
  lang,
  setLang,
  onSignOut,
}: {
  session: Session
  overview: Overview | null
  theme: Theme
  setTheme: (value: Theme) => void
  preset: Preset
  setPreset: (value: Preset) => void
  density: Density
  setDensity: (value: Density) => void
  lang: Lang
  setLang: (value: Lang) => void
  onSignOut: () => void
}) {
  const { t } = useT()
  return (
    <>
      <Panel title={t('settings.appearance')} question={t('settings.remembered')}>
        {/* One setting per row: the name on the left, the choice on the right. */}
        <div className="settings-list">
          <div className="setting">
            <span className="setting-name">
              <Icon name="translate" /> {t('settings.language')}
            </span>
            <Segmented
              label={t('settings.language')}
              value={lang}
              onChange={setLang}
              options={[
                { value: 'bn', label: 'বাংলা' },
                { value: 'en', label: 'English' },
              ]}
            />
          </div>
          <div className="setting">
            <span className="setting-name">
              <Icon name="contrast" /> {t('settings.theme')}
            </span>
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
          <div className="setting">
            <span className="setting-name">
              <Icon name="palette" /> {t('settings.palette')}
            </span>
            <div className="setting-control">
              <PresetPicker value={preset} onChange={setPreset} />
              <p className="dim">{t('settings.palette.note')}</p>
            </div>
          </div>
          <div className="setting">
            <span className="setting-name">
              <Icon name="dashboard" /> {t('settings.density')}
            </span>
            <Segmented
              label={t('settings.density')}
              value={density}
              onChange={setDensity}
              options={[
                { value: 'comfortable', label: t('settings.comfortable') },
                { value: 'compact', label: t('settings.compact') },
              ]}
            />
          </div>
        </div>
        <p className="panel-note">{t('settings.note')}</p>
      </Panel>

      <Panel title={t('settings.session')} question={t('settings.session.q')}>
        <div className="grid g-3">
          <Tile label={t('settings.signedin')} value={session.username} badge="RULE" small />
          <Tile label={t('settings.expires')} value={`${fx(hoursLeft(session), 1)} ${t('unit.hours')}`} badge="RULE" small />
          <Tile label={t('settings.token')} value={t('settings.token.value')} badge="RULE" small />
        </div>
        <div className="note">
          <Icon name="warning" />
          <div>
            <b>{t('settings.notprod.title')}</b> {t('settings.notprod.body')}
          </div>
        </div>
        <div className="toolbar">
          <button onClick={onSignOut}>
            <Icon name="logout" />
            {t('top.signout')}
          </button>
        </div>
      </Panel>

      {overview && (
        <Panel title={t('settings.build')} question={t('settings.build.q')}>
          <div className="table-wrap">
            <table>
              <tbody>
                <tr>
                  <td>{t('settings.row.built')}</td>
                  <td className="mono">{dhakaTime(overview.generated_at)}</td>
                </tr>
                <tr>
                  <td>{t('settings.row.seed')}</td>
                  <td className="mono">
                    {overview.source.seed_dir} · {t('settings.row.checksum')} {overview.source.checksum?.slice(0, 16)}…
                  </td>
                </tr>
                <tr>
                  <td>{t('settings.row.engine')}</td>
                  <td className="mono">
                    {overview.source.service} · {overview.source.model_version}
                  </td>
                </tr>
                <tr>
                  <td>{t('settings.row.mule')}</td>
                  <td className="mono">{overview.source.mule_model_version}</td>
                </tr>
                <tr>
                  <td>{t('settings.row.data')}</td>
                  <td>
                    <span className="chip t-warn">
                      <Icon name="warning" />
                      {t('badge.SYNTHETIC')}
                    </span>{' '}
                    {t('settings.row.data.value')}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </Panel>
      )}
    </>
  )
}
