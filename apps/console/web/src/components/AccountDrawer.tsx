/**
 * One account, everything we know.
 *
 * This is where the numbers on the overview lead. Every figure on this console owes a drill-down,
 * and for an account-shaped figure this is it: the model's score with its reasons, the ring it
 * belongs to, the devices it shares, and every transaction it made.
 */

import { useEffect, useState } from 'react'
import type { Account } from '../lib/types'
import { getAccount } from '../lib/api'
import { dhakaTime, digits, fx, n, taka } from '../lib/format'
import { Rolling } from './Rolling'
import { Badge, Chip } from './primitives'
import { useT } from '../lib/i18n'
import { useLeave } from '../lib/ui'
import { DrawerSkeleton } from './primitives'
import { Icon } from './Wordmark'

export function AccountDrawer({ acctId, onClose }: { acctId: string; onClose: () => void }) {
  const { t, lang } = useT()
  const [leaving, close] = useLeave(onClose)
  const [account, setAccount] = useState<Account | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    setAccount(null)
    setError(null)
    getAccount(acctId)
      .then(setAccount)
      .catch((err: Error) => setError(err.message))
  }, [acctId])

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => event.key === 'Escape' && close()
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [close])

  const maxContribution = Math.max(...(account?.mule?.reasons.map((r) => Math.abs(r.contribution)) ?? [1]), 1)

  return (
    <>
      <div className={`scrim${leaving ? ' leaving' : ''}`} onClick={close} />
      <aside className={`drawer${leaving ? ' leaving' : ''}`} role="dialog" aria-modal="true">
        <div className="head">
          <div className="row">
            <h2 className="drawer-title mono">{acctId}</h2>
            {account && <Badge kind={account.badge} />}
            <span className="spacer" />
            <button className="sm" onClick={close}>
              <Icon name="close" />
              {t('drawer.close')}
            </button>
          </div>
        </div>
        <div className="body">
          {error && <div className="error">{error}</div>}
          {!account && !error && <DrawerSkeleton />}
          {account && (
            <>
              <div className="row">
                <Chip kind="info">{account.kind}</Chip>
                <Chip kind="muted">{account.district}</Chip>
                <Chip kind={account.status === 'active' ? 'good' : 'warn'}>{account.status}</Chip>
                {account.label && (
                  <>
                    <Chip kind="violet">{account.label.role}</Chip>
                    <Chip kind="bad">{account.label.typology}</Chip>
                    <Chip kind="muted">{account.label.ring_id}</Chip>
                  </>
                )}
              </div>

              {account.mule && (
                <>
                  <h3 className="drawer-h">
                    {t('drawer.mulemodel')} · <span className="mono">{account.mule.model_version}</span>
                  </h3>
                  <div className="tile">
                    <div className="row">
                      <span className="value">
                        <Rolling text={fx(account.mule.probability, 4)} />
                      </span>
                      <Chip kind={account.mule.known ? 'good' : 'muted'}>
                        {account.mule.known ? t('live.known') : t('live.unknown')}
                      </Chip>
                    </div>
                    <div style={{ marginTop: 8 }}>
                      {account.mule.reasons.slice(0, 6).map((reason) => (
                        <div
                          key={reason.feature}
                          className="shap-row"
                        >
                          <span className="mono dim" title={reason.feature}>{reason.feature}</span>
                          <div className="bar">
                            <i
                              style={{
                                width: `${Math.min(100, (100 * Math.abs(reason.contribution)) / maxContribution)}%`,
                                background: reason.direction === 'up' ? 'var(--bad-fill)' : 'var(--good-fill)',
                              }}
                            />
                          </div>
                          <span className="mono num">
                            {reason.contribution > 0 ? '+' : reason.contribution < 0 ? '−' : ''}
                            {digits(String(Math.abs(reason.contribution)))}
                          </span>
                        </div>
                      ))}
                    </div>
                  </div>
                </>
              )}

              {account.shared_device_accounts.length > 0 && (
                <>
                  <h3 className="drawer-h">
                    {t('drawer.shares')} {n(account.shared_device_accounts.length)} {t('drawer.accounts')}
                  </h3>
                  <div className="row">
                    {account.shared_device_accounts.slice(0, 12).map((other) => (
                      <span key={other} className="chip t-violet">
                        {other}
                      </span>
                    ))}
                  </div>
                </>
              )}

              <h3 className="drawer-h">
                {t('drawer.txns')} · {n(account.transaction_count)}
                {account.transactions_truncated && (
                  <span className="dim"> ({t('drawer.recent')})</span>
                )}
              </h3>
              <div className="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th>{t('drawer.when')}</th>
                      <th>{t('drawer.type')}</th>
                      <th className="num">{t('drawer.amount')}</th>
                      <th>{t('drawer.counterparty')}</th>
                      <th>{t('drawer.ring')}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {account.transactions.slice(0, 40).map((txn) => (
                      <tr key={txn.txn_id}>
                        <td className="mono">{dhakaTime(txn.ts)}</td>
                        <td>
                          <Chip kind={txn.direction === 'out' ? 'warn' : 'info'}>{txn.type}</Chip>
                        </td>
                        <td className="num">{taka(txn.amount_bdt, lang)}</td>
                        <td className="mono">{txn.counterparty}</td>
                        <td>{txn.ring_id ? <Chip kind="bad">{txn.ring_id}</Chip> : ''}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </div>
      </aside>
    </>
  )
}
