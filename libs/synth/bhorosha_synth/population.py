"""Entities: customers, accounts, SIMs, devices, agents, merchants, personas. No transactions here."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from datetime import datetime, timedelta

import numpy as np
from faker import Faker

from bhorosha_synth import schema as s

Rows = tuple[dict, ...]

PHONE_MODELS: tuple[str, ...] = ("Xiaomi Redmi 9A", "Samsung Galaxy A05", "Tecno Spark 10", "Realme C11", "itel A60", "Symphony Z42", "Walton Primo")
PHONE_WEIGHTS: tuple[float, ...] = (0.22, 0.18, 0.16, 0.14, 0.10, 0.10, 0.10)
DISTRICT_CENTROIDS: dict[str, tuple[float, float]] = {
    "Dhaka": (23.81, 90.41), "Gazipur": (23.99, 90.42), "Chattogram": (22.35, 91.83), "Rangpur": (25.74, 89.27),
    "Sylhet": (24.90, 91.87), "Bhola": (22.69, 90.64), "Narayanganj": (23.62, 90.50), "Khulna": (22.85, 89.54),
}
ACCOUNT_AGE_DAYS_MAX = 730
TELCO_ACCT = "acct_telco_recharge"


@dataclass(frozen=True)
class Population:
    customers: Rows
    accounts: Rows
    sims: Rows
    sim_events: Rows
    devices: Rows
    device_links: Rows
    agents: Rows
    merchants: Rows
    window_start: datetime


def _h(*parts: object) -> str:
    return hashlib.sha256(":".join(str(p) for p in parts).encode()).hexdigest()[:16]


# Id helpers: the one place each id format lives. Typologies that open accounts (the call-centre campaign) ask these.
def customer_id(n: int) -> str:
    return f"cust_{n:05d}"


def account_id(cust_id: str) -> str:
    return f"acct_{cust_id[5:]}"


def sim_id(acct_id: str, seed: int) -> str:
    return f"sim_{_h('sim', acct_id, seed)}"


def device_id(acct_id: str, seed: int) -> str:
    return f"dev_{_h('dev', acct_id, seed)}"


def stable_hash(*parts: object) -> str:
    """The population's 16-hex hash (nid, phone and IMSI hashes)."""
    return _h(*parts)


def _pick(rng: np.random.Generator, options: tuple, weights: tuple[float, ...] | None = None):
    idx = rng.choice(len(options), p=np.asarray(weights) / sum(weights) if weights else None)
    return options[int(idx)]


def _past_date(rng: np.random.Generator, window_start: datetime, max_days: int = ACCOUNT_AGE_DAYS_MAX, min_days: int = 1) -> datetime:
    return window_start - timedelta(days=int(rng.integers(min_days, max_days)), hours=int(rng.integers(0, 24)))


def _agents(rng: np.random.Generator, faker: Faker, cfg: s.WorldConfig, window_start: datetime) -> Rows:
    ids = tuple(f"AG-{i:04d}" for i in range(1, cfg.agents)) + (s.COLLUDING_AGENT_ID,)
    rows = []
    for agent_id in ids:
        district = _pick(rng, s.DISTRICTS, s.DISTRICT_WEIGHTS)
        lat, lon = DISTRICT_CENTROIDS[district]
        rows.append({
            "agent_id": agent_id, "acct_id": f"acct_till_{agent_id}", "name": faker.name(), "district": district,
            "lat": round(lat + float(rng.normal(0, 0.05)), 5), "lon": round(lon + float(rng.normal(0, 0.05)), 5),
            "commission_rate": 0.0041, "since": s.format_ts(_past_date(rng, window_start, 1500, 90)),
        })
    return tuple(rows)


# Generic Bangla shop names per category. Faker's bn_BD company list holds real businesses, so the generator does
# not use it for merchant names.
MERCHANT_LABELS_BN = {"grocery": "মুদি দোকান", "pharmacy": "ফার্মেসি", "clothing": "পোশাকের দোকান",
                      "electronics": "ইলেকট্রনিক্সের দোকান", "restaurant": "রেস্তোরাঁ", "utility": "ইউটিলিটি সেবা"}
BN_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def _merchants(rng: np.random.Generator, faker: Faker, cfg: s.WorldConfig, window_start: datetime) -> Rows:
    categories = ("grocery", "pharmacy", "clothing", "electronics", "restaurant", "utility")
    rows = []
    for i in range(1, cfg.merchants + 1):
        merchant_id = f"MR-{i:04d}"
        faker.company()  # drawn and discarded so that the Faker stream (and every later name) stays the same
        category = categories[int(rng.integers(0, len(categories)))]
        rows.append({
            "merchant_id": merchant_id, "acct_id": f"acct_merchant_{merchant_id}",
            "name": f"{MERCHANT_LABELS_BN[category]} {str(i).translate(BN_DIGITS)}",
            "category": category, "district": _pick(rng, s.DISTRICTS, s.DISTRICT_WEIGHTS),
            "since": s.format_ts(_past_date(rng, window_start, 1500, 60)),
        })
    return tuple(rows)


def _persona_customers(window_start: datetime) -> Rows:
    created = s.format_ts(window_start - timedelta(days=400))
    return (
        {"cust_id": s.RINA_CUST, "name": "রিনা আক্তার", "name_en": "Rina Akter", "gender": "F", "age": s.RINA_AGE, "district": "Gazipur",
         "segment": "garment_worker", "nid_hash": _h("nid", s.RINA_CUST), "phone_hash": _h("ph", s.RINA_CUST), "onboarding_agent_id": "AG-0003", "created_at": created, "persona": "rina"},
        {"cust_id": s.RAFIQ_CUST, "name": "রফিক ইসলাম", "name_en": "Rafiq Islam", "gender": "M", "age": 34, "district": s.RAFIQ_DISTRICT,
         "segment": "trader", "nid_hash": _h("nid", s.RAFIQ_CUST), "phone_hash": _h("ph", s.RAFIQ_CUST), "onboarding_agent_id": "AG-0011", "created_at": created, "persona": "rafiq"},
        {"cust_id": s.RAHIMA_CUST, "name": "রহিমা বেগম", "name_en": "Rahima Begum", "gender": "F", "age": 67, "district": "Bhola",
         "segment": "elderly", "nid_hash": _h("nid", s.RAHIMA_CUST), "phone_hash": _h("ph", s.RAHIMA_CUST), "onboarding_agent_id": "AG-0020", "created_at": created, "persona": "rahima"},
        {"cust_id": "cust_newphone_benign", "name": "সুমন মিয়া", "name_en": "Sumon Mia", "gender": "M", "age": 31, "district": "Dhaka",
         "segment": "service_holder", "nid_hash": _h("nid", "benign"), "phone_hash": _h("ph", "benign"), "onboarding_agent_id": "AG-0001", "created_at": created, "persona": "benign_new_phone"},
    )


def _customers(rng: np.random.Generator, faker: Faker, cfg: s.WorldConfig, window_start: datetime, agents: Rows) -> Rows:
    agents_by_district: dict[str, tuple[str, ...]] = {}
    for a in agents:
        agents_by_district = {**agents_by_district, a["district"]: agents_by_district.get(a["district"], ()) + (a["agent_id"],)}
    all_agent_ids = tuple(a["agent_id"] for a in agents)
    rows = []
    for i in range(cfg.customers):
        district = _pick(rng, s.DISTRICTS, s.DISTRICT_WEIGHTS)
        segment = _pick(rng, s.SEGMENTS, s.SEGMENT_WEIGHTS)
        age = int(rng.integers(62, 80)) if segment == "elderly" else int(rng.integers(19, 58))
        local = agents_by_district.get(district, all_agent_ids)
        rows.append({
            "cust_id": customer_id(i), "name": faker.name(), "gender": "F" if rng.random() < 0.45 else "M", "age": age,
            "district": district, "segment": segment, "nid_hash": _h("nid", i, cfg.seed), "phone_hash": _h("ph", i, cfg.seed),
            "onboarding_agent_id": local[int(rng.integers(0, len(local)))], "created_at": s.format_ts(_past_date(rng, window_start)), "persona": None,
        })
    return tuple(rows)


def _accounts(customers: Rows, agents: Rows, merchants: Rows, window_start: datetime) -> Rows:
    persona_acct = {s.RINA_CUST: s.RINA_ACCT, s.RAFIQ_CUST: s.RAFIQ_ACCT, s.RAHIMA_CUST: s.RAHIMA_ACCT, "cust_newphone_benign": s.BENIGN_SIM_SWAP_ACCT}
    customer_accts = tuple(
        {"acct_id": persona_acct.get(c["cust_id"], account_id(c["cust_id"])), "owner_id": c["cust_id"], "kind": "customer", "district": c["district"],
         "opened_at": c["created_at"], "onboarding_agent_id": c["onboarding_agent_id"], "status": "active"}
        for c in customers
    )
    till_accts = tuple({"acct_id": a["acct_id"], "owner_id": a["agent_id"], "kind": "agent_till", "district": a["district"], "opened_at": a["since"], "onboarding_agent_id": None, "status": "active"} for a in agents)
    merchant_accts = tuple({"acct_id": m["acct_id"], "owner_id": m["merchant_id"], "kind": "merchant", "district": m["district"], "opened_at": m["since"], "onboarding_agent_id": None, "status": "active"} for m in merchants)
    system = (
        {"acct_id": s.PAYROLL_ACCT, "owner_id": "org_garments_payroll", "kind": "payroll", "district": "Gazipur", "opened_at": s.format_ts(window_start - timedelta(days=900)), "onboarding_agent_id": None, "status": "active"},
        {"acct_id": TELCO_ACCT, "owner_id": "org_telco", "kind": "merchant", "district": "Dhaka", "opened_at": s.format_ts(window_start - timedelta(days=900)), "onboarding_agent_id": None, "status": "active"},
    )
    return customer_accts + till_accts + merchant_accts + system


def _sims_and_devices(rng: np.random.Generator, accounts: Rows, cfg: s.WorldConfig) -> tuple[Rows, Rows, Rows, Rows]:
    sims, events, devices, links = [], [], [], []
    for n, acct in enumerate(a for a in accounts if a["kind"] == "customer"):
        sim = sim_id(acct["acct_id"], cfg.seed)
        device = device_id(acct["acct_id"], cfg.seed)
        sims.append({"sim_id": sim, "acct_id": acct["acct_id"], "imsi_hash": _h("imsi", n, cfg.seed), "activated_at": acct["opened_at"], "active": True})
        events.append({"event": "activate", "acct_id": acct["acct_id"], "sim_id": sim, "ts": acct["opened_at"], "new_sim_id": None})
        devices.append({"device_id": device, "model": _pick(rng, PHONE_MODELS, PHONE_WEIGHTS), "os": f"Android {int(rng.integers(11, 15))}", "first_seen": acct["opened_at"]})
        links.append({"acct_id": acct["acct_id"], "device_id": device, "first_seen": acct["opened_at"], "is_primary": True})
    return tuple(sims), tuple(events), tuple(devices), tuple(links)


def build_population(rng: np.random.Generator, faker: Faker, cfg: s.WorldConfig) -> Population:
    window_start = datetime.strptime(cfg.start_date, "%Y-%m-%d")
    agents = _agents(rng, faker, cfg, window_start)
    merchants = _merchants(rng, faker, cfg, window_start)
    customers = _persona_customers(window_start) + _customers(rng, faker, cfg, window_start, agents)
    accounts = _accounts(customers, agents, merchants, window_start)
    sims, sim_events, devices, device_links = _sims_and_devices(rng, accounts, cfg)
    return Population(customers, accounts, sims, sim_events, devices, device_links, agents, merchants, window_start)
