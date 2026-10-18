/** What the keyboard does. Opened with ? and from the command palette. */

import { useT } from '../lib/i18n'
import { useLeave } from '../lib/ui'

/** [keys, what], where `what` is a string key; `g then o` reads in the active language. */
const KEYS: [string[], string][] = [
  [['⌘K', 'ctrl K'], 'help.palette'],
  [['g', 'o'], 'view.overview'],
  [['g', 'g'], 'view.gates'],
  [['g', 'r'], 'view.risk'],
  [['g', 'a'], 'view.accounts'],
  [['g', 'u'], 'view.logs'],
  [['g', 'c'], 'view.cases'],
  [['g', 'i'], 'view.campaigns'],
  [['g', 't'], 'view.cashout'],
  [['g', 'm'], 'view.models'],
  [['g', 'l'], 'view.live'],
  [['g', 's'], 'view.settings'],
  [['/'], 'help.search'],
  [['?'], 'help.help'],
  [['esc'], 'help.esc'],
]

export function ShortcutHelp({ onClose }: { onClose: () => void }) {
  const { t } = useT()
  const [leaving, close] = useLeave(onClose)
  return (
    <>
      <div className={`scrim${leaving ? ' leaving' : ''}`} onClick={close} />
      <div className={`palette palette--narrow${leaving ? ' leaving' : ''}`} role="dialog" aria-modal="true" aria-label={t('help.keyboard')}>
        <h2 className="palette-title">{t('help.keyboard')}</h2>
        <div className="palette-list">
          {KEYS.map(([keys, what]) => (
            <div className="palette-item" key={keys.join('+')}>
              <span>
                {keys[0] === 'g' ? (
                  <>
                    <kbd>g</kbd> {t('help.then')} <kbd>{keys[1]}</kbd>
                  </>
                ) : (
                  keys.map((key, index) => (
                    <span key={key}>
                      {index > 0 && ' / '}
                      <kbd>{key}</kbd>
                    </span>
                  ))
                )}
              </span>
              <span className="hint">{t(what)}</span>
            </div>
          ))}
        </div>
        <div className="palette-foot">
          <kbd>esc</kbd> {t('palette.close')}
        </div>
      </div>
    </>
  )
}
