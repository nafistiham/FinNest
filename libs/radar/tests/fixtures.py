"""Small fixture world, deliberately unrelated to the generated seed worlds."""
from datetime import datetime,timedelta
import json


def write_rows(path,rows):
    path.write_text(''.join(json.dumps(row)+'\n' for row in rows))


PAYDAY_SHOP='shop'  # a merchant that workers pay on payday


def payday_shop_burst(attempts):
    """Payday (the 10th) at the shop: twelve distinct senders in twelve minutes, the 15-minute velocity cap. The week
    before, six senders paid it at the same hour. It stays quiet only through the payday factor (without it the
    p-branch fires) and the busy-payee guard (a customer payee would trip the cap)."""
    for day,senders in ((3,6),(10,12)):
        attempts.extend(dict(attempt_id=f'shop_{day}_{i}',ts=f'2026-10-{day:02}T10:{i:02}:00',from_acct=f'worker_{day}_{i}',
                             to_acct=PAYDAY_SHOP,amount_bdt=800,type='send_money',is_new_payee=True,decision='allow') for i in range(senders))
    return dict(burst_id='payday_1',kind='payday_1',start='2026-10-10T10:00:00',end='2026-10-10T11:00:00',
                acct_ids=[f'worker_10_{i}' for i in range(12)],types=['send_money'])


def seed_fixture(path,*,shop_kind='merchant'):
    path.mkdir(parents=True,exist_ok=True)
    start=datetime(2026,10,17,10)
    attempts=[dict(attempt_id=f'a{i:02}',ts=(start+timedelta(minutes=i)).isoformat(),from_acct=f'v{i:02}',
        to_acct=f'p{i%3}',amount_bdt=3000,type='send_money',is_new_payee=True,channel='app',
        decision='allow' if i<11 else 'hold',truth_campaign='c') for i in range(30)]
    attempts.append(dict(attempt_id='outcome',ts='2026-10-17T10:31:00',from_acct='p0',to_acct='till',amount_bdt=1000,
                        type='cash_out',decision='allow',truth_campaign='c'))
    bursts=[payday_shop_burst(attempts)]
    for day,kind in ((19,'payday_2'),(20,'wedding'),(21,'hospital')):
        ids=[f'{kind}_v{i}' for i in range(6)]
        bursts.append(dict(burst_id=kind,kind=kind,start=f'2026-10-{day}T10:00:00',end=f'2026-10-{day}T11:00:00',acct_ids=ids,types=['send_money']))
        attempts.extend(dict(attempt_id=f'{kind}_{i}',ts=f'2026-10-{day}T10:0{i}:00',from_acct=sender,to_acct=kind,
                             amount_bdt=500,type='send_money',is_new_payee=True,decision='allow') for i,sender in enumerate(ids))
    write_rows(path/'attempts.jsonl',attempts)
    write_rows(path/'labels.jsonl',[dict(acct_id=f'v{i:02}',ring_id='c',role='victim',typology='callcentre_campaign') for i in range(30)])
    write_rows(path/'transactions.jsonl',[dict(txn_id='cashout',ts='2026-10-17T10:31:00',from_acct='p0',to_acct='till',
                                             amount_bdt=1000,type='cash_out',ring_id='c',agent_id='opaque')])
    write_rows(path/'accounts.jsonl',[dict(acct_id=f'p{i}',district='Bhola',kind='customer',onboarding_agent_id='shared',opened_at='2026-10-01T00:00:00') for i in range(3)] +
               [dict(acct_id=f'v{i:02}',district='Dhaka',kind='customer',onboarding_agent_id=f'v_agent{i}') for i in range(30)] +
               [dict(acct_id=PAYDAY_SHOP,district='Gazipur',kind=shop_kind,opened_at='2026-09-01T00:00:00')])
    write_rows(path/'agents.jsonl',[dict(agent_id='shared')])
    write_rows(path/'bursts.jsonl',bursts)
    (path/'config.json').write_text(json.dumps(dict(seed=42,start_date='2026-10-01',days=22)))
    return path
