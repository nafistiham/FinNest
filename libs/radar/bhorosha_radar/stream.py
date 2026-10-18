"""Observable attempt stream; enrichment uses only relations available at its timestamp."""
from __future__ import annotations

from bisect import bisect_right
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, replace
from datetime import datetime
import json
import math
from pathlib import Path
from zoneinfo import ZoneInfo

import pandas as pd

from .config import AMOUNT_BANDS, CELL_TYPES, DECISIONS, SIM_DAY_RECENT_DAYS


@dataclass(frozen=True)
class Attempt:
    attempt_id: str
    ts: str
    sender: str
    payee: str | None
    amount_bdt: float
    type: str
    is_new_payee: bool
    channel: str | None
    decision: str
    source: str
    sender_district: str | None = None
    payee_district: str | None = None
    payee_onboarding_agent: str | None = None
    payee_devices: tuple[str, ...] = ()
    payee_sim_day: str | None = None
    payee_till: str | None = None
    payee_next_hops: tuple[str, ...] = ()
    sender_minutes_since_sim_change: float | None = None
    amount_band: str = ''
    processing_ms: float | None = None
    identity_source: str | None = None
    payee_kind: str | None = None


def to_local(ts: str) -> str:
    parsed = datetime.fromisoformat(ts.replace('Z', '+00:00'))
    if parsed.tzinfo is not None:
        parsed = parsed.astimezone(ZoneInfo('Asia/Dhaka')).replace(tzinfo=None)
    return parsed.isoformat(timespec='seconds')


def amount_band(amount_bdt: float) -> str:
    return f'band_{bisect_right(AMOUNT_BANDS, amount_bdt)}'


def _amount(value) -> float:
    if isinstance(value, bool):
        raise ValueError('amount must be numeric, not boolean')
    amount = float(value or 0)
    if not math.isfinite(amount) or amount < 0:
        raise ValueError('amount must be finite and nonnegative')
    return amount


def read_seed(seed_dir: Path) -> tuple[Attempt, ...]:
    path = seed_dir / 'attempts.jsonl'
    source = 'seed' if path.exists() else 'ledger_only'
    path = path if path.exists() else seed_dir / 'transactions.jsonl'
    if not path.exists():
        return ()
    attempts = []
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if source == 'ledger_only' and row.get('type') != 'send_money':
            continue
        decision = row.get('decision', 'allow' if source == 'ledger_only' else None)
        if decision not in DECISIONS:
            raise ValueError(f'unsupported attempt decision: {decision!r}')
        amount = _amount(row.get('amount_bdt'))
        attempts.append(Attempt(attempt_id=row.get('attempt_id') or row['txn_id'], ts=to_local(row['ts']),
            sender=row['from_acct'], payee=row.get('to_acct'), amount_bdt=amount, type=row['type'],
            is_new_payee=bool(row.get('is_new_payee', False)), channel=row.get('channel'),
            decision=decision, source=source, amount_band=amount_band(amount)))
    ids = [a.attempt_id for a in attempts]
    if len(set(ids)) != len(ids):
        raise ValueError('duplicate attempt_id')
    return tuple(sorted(attempts, key=lambda a: (a.ts, a.attempt_id)))


def _audit_txn(inputs) -> dict:
    txn = inputs.get('txn') or {}
    if not isinstance(txn, dict):
        raise ValueError('txn must be an object')
    payee = txn.get('to_account')
    if payee is not None and (not isinstance(payee, str) or not payee):
        raise ValueError('to_account must be a nonempty string or null')
    if txn.get('type') not in ('pin_reset', 'new_payee', 'send_money'):
        raise ValueError('unsupported transaction type')
    if not isinstance(txn.get('is_new_payee', False), bool):
        raise ValueError('is_new_payee must be boolean')
    return txn


def _audit_sender(user, uid, uid_to_acct, known) -> tuple[str, str]:
    """(sender account, how it was resolved): a known account, then the uid mapping, then the document uid."""
    if user in known:
        return user, 'inputs.user_id_account'
    if user in uid_to_acct:
        return uid_to_acct[user], 'inputs.user_id_mapping'
    if uid in uid_to_acct:
        return uid_to_acct[uid], 'uid_mapping'
    if not isinstance(uid, str) or not uid:
        raise ValueError('unresolved sender without uid')
    return 'uid:' + uid, 'unresolved_uid'


def _audit_attempt(doc, uid_to_acct, known) -> Attempt:
    """One score document as an Attempt; raises ValueError naming the first malformed field."""
    inputs, outputs = doc.get('inputs'), doc.get('outputs')
    if not isinstance(inputs, dict) or not isinstance(outputs, dict):
        raise ValueError('inputs and outputs must be objects')
    txn = _audit_txn(inputs)
    decision = outputs.get('decision')
    if decision not in DECISIONS:
        raise ValueError('unsupported decision')
    if not isinstance(doc.get('at'), str):
        raise ValueError('missing at timestamp')
    sender, identity = _audit_sender(inputs.get('user_id'), doc.get('uid'), uid_to_acct, known)
    aid = doc.get('id')
    if not isinstance(aid, str) or not aid:
        raise ValueError('missing document id')
    amount = _amount(txn.get('amount_bdt'))
    flags = inputs.get('demo_flags') or {}
    if not isinstance(flags, dict):
        raise ValueError('demo_flags must be an object')
    return Attempt(attempt_id=aid, ts=to_local(doc['at']), sender=sender,
        payee=txn.get('to_account'), amount_bdt=amount, type=txn.get('type', ''),
        is_new_payee=bool(txn.get('is_new_payee', False)), channel='app', decision=decision,
        source='audit', sender_minutes_since_sim_change=0.0 if flags.get('sim_swap') else None,
        amount_band=amount_band(amount), processing_ms=doc.get('processing_ms'), identity_source=identity)


def read_audit(path: Path, uid_to_acct: Mapping[str, str], *, known_accounts=()) -> tuple[tuple[Attempt, ...], tuple[dict, ...]]:
    """Score documents from a JSONL audit export; a malformed document is a reject with its reason, never a raise."""
    attempts, rejects = [], []
    known = set(known_accounts) | set(uid_to_acct.values())
    seen = set()
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        if not line.strip():
            continue
        doc = None
        try:
            doc = json.loads(line)
            if not isinstance(doc, dict):
                raise ValueError('document must be an object')
            if doc.get('kind') != 'score':
                continue
            attempt = _audit_attempt(doc, uid_to_acct, known)
            if attempt.attempt_id in seen:
                raise ValueError('duplicate document id')
            attempts.append(attempt)
            seen.add(attempt.attempt_id)
        except (ValueError, TypeError, KeyError, AttributeError) as exc:
            rejects.append({'line': number, 'id': doc.get('id') if isinstance(doc, dict) else None, 'reason': str(exc)})
    return tuple(attempts), tuple(rejects)


def enrich(attempts: Sequence[Attempt], bundle) -> tuple[Attempt, ...]:
    result = []
    for a in attempts:
        ts = datetime.fromisoformat(a.ts)
        sender, payee = bundle.accounts.get(a.sender, {}), bundle.accounts.get(a.payee, {})
        devices = tuple(sorted({d['device_id'] for d in bundle.device_links if d['acct_id'] == a.payee and d['first_seen'] <= a.ts}))
        events = [e for e in bundle.sim_events if e['ts'] <= a.ts and e.get('event') in ('activate', 'swap')]
        sim_dates = [s['activated_at'] for s in bundle.sims if s['acct_id'] == a.payee and s['activated_at'] <= a.ts]
        sim_dates += [e['ts'] for e in events if e['acct_id'] == a.payee]
        last_sim = max(sim_dates, default=None)
        recent = last_sim if last_sim and (ts - datetime.fromisoformat(last_sim)).total_seconds() <= SIM_DAY_RECENT_DAYS * 86400 else None
        sender_swaps = [e['ts'] for e in events if e['acct_id'] == a.sender and e['event'] == 'swap']
        sim_minutes = a.sender_minutes_since_sim_change
        if sim_minutes is None and sender_swaps:
            sim_minutes = (ts - datetime.fromisoformat(max(sender_swaps))).total_seconds() / 60
        txns = [t for t in bundle.txns_by_acct.get(a.payee, ()) if t['ts'] < a.ts and t['from_acct'] == a.payee]
        cashouts = [t for t in txns if t['type'] == 'cash_out']
        last_cashout = max(cashouts, key=lambda t: t['ts'], default={})
        result.append(replace(a, sender_district=sender.get('district'), payee_district=payee.get('district'),
            payee_onboarding_agent=payee.get('onboarding_agent_id'), payee_devices=devices,
            payee_sim_day=recent[:10] if recent else None, payee_till=last_cashout.get('agent_id'),
            payee_next_hops=tuple(sorted({t['to_acct'] for t in txns if t['type'] == 'send_money'})),
            sender_minutes_since_sim_change=sim_minutes, amount_band=amount_band(a.amount_bdt), payee_kind=payee.get('kind')))
    return tuple(result)


def to_frame(attempts: Sequence[Attempt], key: str) -> pd.DataFrame:
    rows = []
    for a in attempts:
        if a.type not in CELL_TYPES or not a.payee or (key.startswith('sender_') and not a.is_new_payee):
            continue
        if key == 'payee_device':
            values = sorted(set(a.payee_devices))
        elif key == 'sender_district_band':
            values = [f'{a.sender_district}:{a.amount_band or amount_band(a.amount_bdt)}'] if a.sender_district else []
        else:
            values = [getattr(a, key)]
        for value in values:
            if value is not None:
                rows.append({'attempt_id': a.attempt_id, 'ts': a.ts, 'sender': a.sender, 'cell': str(value),
                             'busy': key == 'payee_till' or (key == 'payee' and a.payee_kind in ('merchant', 'agent_till'))})
    return pd.DataFrame(rows, columns=['attempt_id', 'ts', 'sender', 'cell', 'busy'])
