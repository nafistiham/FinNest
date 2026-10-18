"""Entity schema, constants and tiny pure helpers for the synthetic FinNest world.

Nothing here does I/O or randomness. Everything downstream (generator, graph, features,
loader, the investigator agent) imports its column names and persona ids from this module.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta

FILE_NAMES: tuple[str, ...] = (
    "customers.jsonl",
    "accounts.jsonl",
    "sims.jsonl",
    "sim_events.jsonl",
    "devices.jsonl",
    "device_links.jsonl",
    "agents.jsonl",
    "merchants.jsonl",
    "transactions.jsonl",
    "labels.jsonl",
)

TXN_TYPES: tuple[str, ...] = ("cash_in", "cash_out", "send_money", "payment", "salary", "recharge")
CHANNELS: tuple[str, ...] = ("app", "ussd", "agent")
ACCOUNT_KINDS: tuple[str, ...] = ("customer", "agent_till", "merchant", "payroll")

TYPOLOGIES: tuple[str, ...] = (
    "otp_takeover_cashout",
    "purchased_mule_cluster",
    "ledger_leak_targeting",
    "agent_round_tripping",
    "fan_in_fan_out",
    "dormant_then_active",
)
ROLES: tuple[str, ...] = ("victim", "mule_L1", "mule_L2", "cashout_agent", "purchased_mule", "controller")

# The campaign world: a second world written with `--campaigns`, never over the demo seed. It is the demo
# world plus the call-centre campaigns, the payment-attempt stream and the benign-burst truth. TYPOLOGIES and
# FILE_NAMES above stay the demo world's, so the demo seed, the mule scorer and every fixture are unchanged.
CAMPAIGN_TYPOLOGY = "callcentre_campaign"
CAMPAIGN_FILE_NAMES: tuple[str, ...] = ("attempts.jsonl", "bursts.jsonl")
DECISIONS: tuple[str, ...] = ("allow", "step_up", "delay", "hold", "block")  # risk-mw's decisions; the generator writes allow and hold
ATTEMPT_TYPES: tuple[str, ...] = ("send_money",)  # payment attempts only; cash-outs are outcomes and stay in the ledger
ATTEMPT_FIELDS: tuple[str, ...] = ("attempt_id", "ts", "from_acct", "to_acct", "amount_bdt", "type", "is_new_payee", "channel",
                                   "decision", "txn_id", "truth_campaign")
BURST_FIELDS: tuple[str, ...] = ("burst_id", "kind", "start", "end", "acct_ids", "types")
CAMPAIGN_DAYS: tuple[int, ...] = (12, 22, 30)  # weeks 1, 3 and 4; clear of paydays 3/34, the hospital (9) and the wedding (20)
CAMPAIGN_STREAM = 38  # campaign draws use default_rng([seed, CAMPAIGN_STREAM]); the main stream is untouched
RETRY_STREAM = 381  # held retries draw default_rng([seed, RETRY_STREAM, crc32(ring_id)]), one stream per ring

DISTRICTS: tuple[str, ...] = ("Dhaka", "Gazipur", "Chattogram", "Rangpur", "Sylhet", "Bhola", "Narayanganj", "Khulna")
DISTRICT_WEIGHTS: tuple[float, ...] = (0.30, 0.18, 0.14, 0.10, 0.08, 0.06, 0.08, 0.06)
SEGMENTS: tuple[str, ...] = ("garment_worker", "trader", "student", "elderly", "remittance_family", "service_holder")
SEGMENT_WEIGHTS: tuple[float, ...] = (0.28, 0.20, 0.12, 0.12, 0.13, 0.15)

# Demo personas (ids are stable so the app, the agent and the video all refer to the same rows)
RINA_CUST = "cust_rina"
RINA_ACCT = "acct_rina"
RAFIQ_CUST = "cust_rafiq"
RAFIQ_ACCT = "acct_rafiq"
RAHIMA_CUST = "cust_rahima"
RAHIMA_ACCT = "acct_rahima"
COLLUDING_AGENT_ID = "AG-0192"
COLLUDING_TILL_ACCT = "acct_till_AG-0192"
LEGIT_MERCHANT_ID = "MR-0007"
LEGIT_MERCHANT_ACCT = "acct_merchant_MR-0007"
BENIGN_SIM_SWAP_ACCT = "acct_newphone_benign"
DEMO_RING_ID = "ring_demo_otp"
PAYROLL_ACCT = "acct_payroll_garments"

PAYDAY_OFFSETS: tuple[int, ...] = (3, 34)  # Oct 10 and Nov 10 when the window starts Oct 7
DEMO_TAKEOVER_DAY = 34  # payday afternoon, Nov 10
RINA_MONTHLY_SEND_BDT = 5000.0
RINA_SALARY_BDT = 13500.0
RINA_AGE = 28
RAFIQ_DISTRICT = "Rangpur"  # Pirganj upazila is in Rangpur district

TS_FORMAT = "%Y-%m-%dT%H:%M:%S"


@dataclass(frozen=True)
class WorldConfig:
    seed: int = 42
    start_date: str = "2026-10-07"
    days: int = 35  # covers two monthly paydays (Oct 10 and Nov 10) so the scorer sees benign salary spikes in training
    customers: int = 2000
    agents: int = 40
    merchants: int = 20
    rings_per_typology: int = 3  # spread early/mid/late so every typology appears on both sides of the temporal split
    daily_txn_rate: float = 0.12  # expected non-salary transactions per customer per day


@dataclass(frozen=True)
class CampaignConfig:
    """Present only on the campaign world. campaigns=0 is the campaign-free replay: the demo world plus the attempt
    stream and the burst truth, which the radar's false-incident measurement runs on."""

    campaigns: int = len(CAMPAIGN_DAYS)

    def __post_init__(self) -> None:
        if not 0 <= self.campaigns <= len(CAMPAIGN_DAYS):
            raise ValueError(f"campaigns must be between 0 and {len(CAMPAIGN_DAYS)}")

    @property
    def days(self) -> tuple[int, ...]:
        return CAMPAIGN_DAYS[:self.campaigns]

    def as_config(self) -> dict:
        return {"campaigns": self.campaigns, "days": list(self.days)}


def parse_ts(value: str) -> datetime:
    return datetime.strptime(value, TS_FORMAT)


def format_ts(value: datetime) -> str:
    return value.strftime(TS_FORMAT)


def add_minutes(value: str, minutes: float) -> str:
    return format_ts(parse_ts(value) + timedelta(minutes=minutes))


def hop_count(txns: list[dict] | tuple[dict, ...], source: str, target: str) -> int:
    """Shortest number of transfers from source to target following txn time order; 0 if unreachable."""
    best: dict[str, int] = {source: 0}
    for txn in sorted(txns, key=lambda t: t["ts"]):
        origin, dest = txn["from_acct"], txn["to_acct"]
        if origin in best and (dest not in best or best[origin] + 1 < best[dest]):
            best = {**best, dest: best[origin] + 1}
    return best.get(target, 0)
