# API contract — FinNest Admin: what we consume and what we add

What the console reads from risk-mw (§1) and the `/v1/admin/*` routes it adds (§2). §1 was checked
against a running risk-mw. Sections of §2 marked "built" are served by `api/`; the rest is design.

```
Base URL   $RISK_MW_URL              (http://localhost:8080 for a local risk-mw)
Schemas    GET /openapi.json        (interactive: /docs)
Headers    X-Demo-User: <uid>       demo mode, no sign-in needed
           X-Processing-Time-Ms     on every response, server-side time
```

Bodies are strict (`extra="forbid"`): an unknown field is a `422`, not a silent ignore.

---

## 1. Existing endpoints we consume

Nothing here needs building. The console is a client.

### 1.1 `GET /health` — the status chip

```json
{"status":"ok","service":"risk-mw","model_version":"stub-0.1","demo_mode":true}
```

Used for: the header chip, and the `model_version` stamped on every rendered figure. Polled at most
once every 30 s.

### 1.2 `GET /v1/mule/demo-ring` — the account picker

```json
{"victim":["acct_rina"],
 "mule_L1":["acct_01070"],
 "mule_L2":["acct_00036","acct_01288","acct_01635","acct_01870"],
 "controller":["acct_01341"],
 "cashout_agent":["acct_till_AG-0192"]}
```

Used for: the live panel's account list, with each role as a chip. Fetched once on load.

### 1.3 `GET /v1/mule/score/{acct_id}` — the live model, with reasons

```json
{"acct_id":"acct_01070","known":true,"probability":0.8697,
 "reasons":[{"feature":"hops_to_recent_sim_swap","value":1.0,"contribution":2.7723,"direction":"up"},
            {"feature":"pass_through_ratio_30d","value":1.179,"contribution":2.6652,"direction":"up"}],
 "model_version":"mule-lgbm-0.1","as_of":"2026-11-11T00:00:00"}
```

Ten reasons come back; the console renders the top three as signed contribution bars and the rest
behind a disclosure. `known:false` means the account is not in the model's world — render that as
"unknown to the model", never as probability 0 with no caveat. Fetched on click only.

### 1.4 `POST /v1/investigate` → `GET /v1/investigations/{case_id}[/events]`

```bash
POST /v1/investigate  {"acct_id":"acct_01070"}
  -> {"case_id":"CZ-0005","stream_url":"/v1/investigations/CZ-0005/events"}
```

* A case takes **~45 s, sometimes over a minute**.
* While running: `status` is `queued`/`running`, `summary_en` is `"Investigation in progress."`,
  `evidence` and `ring` are empty, `confidence` is `0.0`, `recommended_action` is `pending`.
* `model_version: "stub-fallback"` means Case Zero was busy or down and the scripted stub answered.
* A repeat request for the same account inside **30 minutes** returns the same case.
* `recommended_action` ∈ `freeze` · `edd` · `monitor` · `close_no_action` · `pending` · `route_to_risk_reviewer`.

The events stream is `text/event-stream`, one `data: {...}` per line, `step` ∈ `plan` · `tool`
(`name`, `args`) · `evidence` (`row_id`, `text`) · `error` (`text`) · `done` (`confidence`).
`done` ends the stream.

**Rate discipline (PLAN §1.4):** this is a Gemini route — 30/min per caller, 90/min shared, and a $5
per-instance spend ledger. **One investigation per explicit click. Never on a timer, never on page
load.**

### 1.5 `POST /v1/risk/score` — the demo control

Used only by the live panel's "what would the engine say" control, so a judge can see a decision
change. Request and response are the frozen contract (`app/contracts.py`). Decisions in order of
severity: `allow` · `step_up` · `delay` · `hold` · `block`.

### 1.6 `POST /v1/risk/signals` — paired with the above (T0-B)

Takes `behaviour.features` — **39 floats** as of `bhorosha_ato.schema.FEATURES`, up to 64 allowed —
and holds them against `session_id` for the next `/v1/risk/score`. Use the **same session id** for both
or the behaviour model contributes nothing.

Verified live tonight: a coached feature vector plus a matching `user_id` returns
`ATO_BEHAVIOUR_MISMATCH` (0.844) and `COACHING_SUSPECTED` (1.0).

`{"stored": true}` is a **hardcoded literal**, not a confirmation that anything persisted
(`app/routers/risk.py:60`). Do not render it as proof of storage.

### 1.7 The ten reason codes the console charts

| Code | Weight | Decision | From |
|---|---|---|---|
| `CALL_ACTIVE_NON_CONTACT` | 0.90 | hold | rules |
| `SIM_CHANGED_24H` | 0.85 | hold | rules |
| `NEW_PAYEE_ABOVE_P95` | 0.60 | delay | rules |
| `APP_SAFETY_BLOCK` | 0.95 | block | rules |
| `DEST_MULE_RISK` | = mule probability | hold | rules + mule model |
| `SCREEN_SHARE_ACTIVE` | 0.50 | step_up | rules |
| `SCAM_CONVERSATION` | = scam score | hold | rules + Gemini |
| `ATO_BEHAVIOUR_MISMATCH` | from the model | step_up/hold | behaviour model |
| `COACHING_SUSPECTED` | from the model | step_up/hold | behaviour model |
| any code + `_COLD_START` | — | — | behaviour model, user has no per-user model yet |

Thresholds: `band_medium` 0.30 · `band_high` 0.60 · `band_critical` 0.85 · `mule_hold_threshold` 0.80 ·
`default_p95_amount_bdt` 5000.

### 1.8 Errors and quotas we must handle

| Status | Meaning | Console behaviour |
|---|---|---|
| `422` | Unknown field or bad value; `detail` names it | Show the field; this is our bug, surface it loudly |
| `429` | Over quota; `Retry-After` in seconds | Show the wait, retry **once**, never loop |
| `404` | Unknown case or request id | "Cases live in memory; a restart forgets them" |
| `502` | Investigator unreachable mid-read | Offer retry, then offer a new case |

Quotas: 300/min per caller on all `/v1`; 30/min per caller and 90/min shared on `/v1/scam/turn` and
`/v1/investigate`.

---

## 2. New endpoints we add, `/v1/admin/*`

Read-only except the T1 disposition. Same error envelope and the same rate-limit dependency as every
other router. Models subclass the `Strict` base from `app/contracts.py` (`extra="forbid"`, `frozen=True`).

### 2.1 `GET /v1/admin/overview` — T0-B

Everything the home screen renders, in one response. Identical shape to the committed
`fixtures/overview.json`, so the console cannot tell whether it is live or static.

**Query**: `from`, `to` (ISO dates, optional; default the whole seed window) · `refresh=true` to bypass
the 5-minute cache.

**Response** (`OverviewResponse`):

```jsonc
{
  "generated_at": "2026-10-17T00:30:00+06:00",
  "window": {"from": "2026-10-07", "to": "2026-11-11", "tz": "Asia/Dhaka", "days": 35},
  "source": {
    "seed_dir": "data/seed", "seed": 42, "checksum": "<data/seed/CHECKSUM>",
    "service": "risk-mw", "model_version": "stub-0.1", "mule_model_version": "mule-lgbm-0.1",
    "synthetic": true
  },

  "world": {"customers": 2004, "accounts": 2066, "transactions": 12122, "agents": 40,
            "merchants": 20, "devices": 2004, "sim_events": 2008, "device_links": 2023,
            "rings": 18, "labelled_accounts": 218},

  "replay": {
    "denominator": 2330, "denominator_label": "send_money transactions",
    "mix":   {"allow": 1985, "step_up": 0, "delay": 210, "hold": 135, "block": 0},
    "bands": {"low": 1985, "medium": 0, "high": 214, "critical": 131},
    "codes": {"NEW_PAYEE_ABOVE_P95": 222, "DEST_MULE_RISK": 135},
    "cooccurrence": {"DEST_MULE_RISK + NEW_PAYEE_ABOVE_P95": 12},
    "codes_that_cannot_fire": ["CALL_ACTIVE_NON_CONTACT", "SIM_CHANGED_24H", "APP_SAFETY_BLOCK",
                               "SCREEN_SHARE_ACTIVE", "SCAM_CONVERSATION",
                               "ATO_BEHAVIOUR_MISMATCH", "COACHING_SUSPECTED"],
    "codes_that_cannot_fire_reason": "the seed carries no call state, SIM change, screen share, app-safety verdict, scam score or behaviour vector",
    "confusion": {"catch": 108, "miss": 103, "false_positive": 27, "true_negative": 2092},
    "rates": {"catch_rate": 0.512, "catch_rate_denominator": 211,
              "false_positive_rate": 0.0127, "false_positive_rate_denominator": 2119,
              "stop_precision": 0.800, "stop_precision_denominator": 135},
    "value": {"protected_bdt": 1936900, "friction_bdt": 62790, "currency": "BDT"},
    "histogram": [1985, 0, 0, 0, 0, 0, 210, 0, 9, 126],
    "daily": [{"d": "2026-10-07", "scored": 61, "stopped": 2}, "…35 entries…"],
    "badge": "RULE"
  },

  "gates": [
    {"id": "G0", "title": "The server decides and executes", "owner_ticket": "risk-mw",
     "sees": "server", "status": "planned", "badge": "NONE",
     "note": "Today a hold is a response body; an attacker who controls the phone can ignore it."},
    {"id": "G1", "title": "Takeover: freeze credential changes after a SIM change or new device",
     "owner_ticket": "risk-mw", "sees": "server", "status": "rule on client flags", "badge": "RULE",
     "volume": null, "caught": null},
    {"id": "G2", "title": "Scam call: call state, screen share, the assistant, turn classifier, app safety",
     "owner_ticket": "mobile / ato / app-safety", "sees": "phone, raise-only", "badge": "MODEL",
     "note": "behaviour model live on risk-mw since 2026-10-16"},
    {"id": "G3", "title": "Sender anomaly: amount, balance drain, never-paid payee, district",
     "owner_ticket": "risk-mw", "badge": "RULE",
     "note": "fixed usual amount today; per-person baseline planned"},
    {"id": "G4", "title": "Payee: mule score, Case Zero watch-list, till risk",
     "owner_ticket": "mule model", "badge": "MODEL", "volume": 429, "caught": 29},
    {"id": "G5", "title": "Cash-out: cooling window on inbound funds carrying takeover signals",
     "owner_ticket": "risk-mw", "status": "planned", "badge": "NONE"},
    {"id": "G6", "title": "After the fact: nightly scoring, Case Zero, freeze what is still inside",
     "owner_ticket": "case-zero", "badge": "MODEL", "note": "freeze and claw-back actions not built"},
    {"id": "G7", "title": "Feedback and sharing: confirmed mules into G4, hashed identifiers",
     "owner_ticket": null, "status": "not built", "badge": "NONE"}
  ],

  "targets": [
    {"id": "false_delays", "label": "False delays per 1,000 customers per month",
     "target": "< 1", "value": null, "badge": "NO DATA",
     "why": "needs a release path and a month of operation"},
    {"id": "minutes_to_release", "label": "Median minutes to release", "target": "< 5",
     "value": null, "badge": "NO DATA"},
    {"id": "self_release", "label": "Delays ended by the customer or a relative", "target": "> 90%",
     "value": null, "badge": "NO DATA"},
    {"id": "money_inside", "label": "Stolen money still inside when the alarm sounds", "target": "> 50%",
     "value": null, "badge": "NO DATA"},
    {"id": "friction_cost", "label": "Friction imposed", "target": "as low as the catch allows",
     "value": 62790, "unit": "BDT", "badge": "RULE"}
  ],

  "mule_board": [
    {"acct": "acct_00177", "p": 1.0, "role": "mule_L1", "typology": "agent_round_tripping",
     "ring": "ring_roundtrip_1",
     "shap": [{"f": "median_forward_minutes_7d", "c": 4.9, "d": "up"}, "…2 more…"]}
  ],
  "mule_board_meta": {"scored": 429, "at_or_above_0_80": 29, "sample_seed": 7, "badge": "MODEL"},

  "models": [
    {"id": "mule-lgbm", "version": "mule-lgbm-0.1", "headline": "AUC-PR 0.841, P@50 0.90",
     "badge": "MODEL", "eval": "eval/results/mule.json",
     "per_segment": {"agent_round_tripping": 1.0, "dormant_then_active": 1.0,
                     "purchased_mule_cluster": 0.611, "ledger_leak_targeting": 0.417,
                     "fan_in_fan_out": 0.31, "otp_takeover_cashout": 0.20}},
    {"id": "ato-identity", "badge": "MODEL", "eval": "libs/ato/eval/results/ato_hmog.json"},
    {"id": "ato-coaching", "badge": "MODEL", "eval": "libs/ato/eval/results/ato.json"},
    {"id": "case-zero", "badge": "MODEL", "eval": "services/case-zero/eval/results/case_zero.json",
     "gates": {"G4_p95_under_60s": false, "measured_p95_s": 64.7}},
    {"id": "app-safety", "badge": "STUB", "eval": null},
    {"id": "fna-intervention", "badge": "STUB", "eval": null}
  ],

  "policy": [
    {"id": "no_model_block", "statement": "No model may reach block; a decline exists only for a payee an analyst has confirmed as a mule",
     "ok": true, "evidence": "block count = 0 over 2,330 scored", "source": "defence-in-depth plan, section 5"},
    {"id": "holds_are_delays", "statement": "Holds are delays with a customer-controlled release",
     "ok": false, "evidence": "no release path exists yet; trusted-contact approve/decline is the nearest thing"},
    {"id": "client_signals_raise_only", "statement": "Client signals only raise risk; the ledger decides",
     "ok": true, "evidence": "every demo_flag enters through a rule that can only add a hit"}
  ],

  "weakest_link": {"typology": "otp_takeover_cashout", "ring_recall": 0.20,
                   "highest_volume_stub": "app-safety"}
}
```

**Rules this shape enforces by construction** — every section carries `badge`; every rate carries a
`*_denominator` sibling; `catch_rate` and `false_positive_rate` live in the same object so one cannot
be served without the other; `source.synthetic` is `true` and the console refuses to render without it.

**Caching**: computed at start-up, cached 5 minutes, served from `fixtures/overview.json` if the
computation has not finished yet. The mule board is the slow part (~40 s, SHAP per account) and is
therefore never computed inside a request.

### 2.2 `GET /v1/admin/account/{acct_id}` — T0-B

The drill-down the fixture cannot hold: one account's transactions, devices, SIM events, shared-device
links, ring membership and every decision ever made about it.

```jsonc
{"acct_id": "acct_01070", "kind": "customer", "district": "Dhaka", "opened_at": "…",
 "owner": {"cust_id": "…", "segment": "garment_worker", "age": 31, "district": "Dhaka"},
 "mule": {"probability": 0.8697, "known": true, "model_version": "mule-lgbm-0.1",
          "reasons": ["…10 SHAP reasons…"]},
 "label": {"ring_id": "ring_demo_otp", "role": "mule_L1", "typology": "otp_takeover_cashout",
           "first_bad_ts": "…"},
 "transactions": [{"txn_id": "…", "ts": "…", "type": "…", "amount_bdt": 0, "counterparty": "…",
                   "direction": "in|out", "channel": "…", "ring_id": null}],
 "devices": ["…"], "sims": ["…"], "sim_events": ["…"], "shared_device_accounts": ["…"],
 "badge": "MODEL", "synthetic": true}
```

Capped at 200 transactions with a `truncated` flag; an account with more is paged, not silently cut.

### 2.3 `GET /v1/admin/models` — T0-B

Reads the eval JSONs server-side so the console needs no filesystem access. Same `models` array as
§2.1, plus the full metric table per model and the file's `mtime` so a stale eval is visible.

### 2.4 T1 endpoints, specified now so T1 does not start from a blank page

| Route | Query | Returns |
|---|---|---|
| `GET /v1/admin/decisions` | `decision`, `band`, `code`, `txn_type`, `amount_min/max`, `district`, `segment`, `model_version`, `from`, `to`, `cursor`, `limit` | `{rows: [...], facets: {field: {value: count}}, next_cursor}` — facets carry counts so a filter is never a guess |
| `GET /v1/admin/decisions/{audit_id}` | — | The stored `audit/{id}` document, **unmodified**: `inputs`, `outputs`, `processing_ms`, `model_version`, `at`. Never recomputed. |
| `GET /v1/admin/cases` | `status`, `owner`, `cursor` | Cases grouped by account → ring → 24 h window, with `priority` and the formula that produced it |
| `POST /v1/admin/cases/{id}/disposition` | body `{disposition, reason_code, note}` | The only write. `disposition` ∈ `confirmed_fraud` · `not_fraud` · `inconclusive` · `escalate`; `reason_code` from a fixed taxonomy, mandatory; four eyes on `freeze`. |
| `POST /v1/admin/simulate` | body `{thresholds: {...}, window}` | Replays stored audit inputs at new thresholds: `{confusion_old, confusion_new, decisions_changed, value_delta, most_affected: [...10 customers...]}` |

T1 reads from BigQuery `bhorosha_analytics.fact_decisions`, dual-written from `app/audit.py` — one
flattened row per decision: `decision`, `band`, `risk_score`, `reason_codes[]`, `amount_bdt`,
`txn_type`, `user_id`, `session_id`, `model_version`, `processing_ms`, `at`. Ten lines in `audit.py`,
and it is the only thing that makes aggregation over real traffic possible.

### 2.5 `GET /v1/admin/campaigns` and `GET /v1/admin/campaigns/{incident_id}` — built

The Incidents view. Both routes
take the operator token and serve `fixtures/campaigns.json`, which `tools/build_campaigns.py` writes by
running the radar (`libs/radar`, through `libs/radar/eval/radar_eval.py`'s own functions) over
`data/seed-campaign` and copying the evaluation from `eval/results/campaign.json`. **No radar
run, Firestore read or Gemini call happens at request time.** The fixture is validated once against
`CampaignsFixture` and kept in memory; a rebuilt file (new mtime or size) is read again.

Every timestamp carries `+06:00`: the radar writes naive Asia/Dhaka strings and the builder appends the
offset (design §3.B). Field names are the radar's own dataclass fields.

**List** — the incident rail and the campaign table (`CampaignsList`):

```jsonc
{"available": true, "generated_at": "…",
 "source": {"seed_dir": "data/seed-campaign", "seed_checksum": "…", "input_checksums": {"attempts.jsonl": "…"},
            "eval_file": "eval/results/campaign.json", "eval_sha256": "…", "producer": "…",
            "timezone": "Asia/Dhaka (+06:00)", "synthetic": true},
 "incidents": [{"incident_id": "inc_3fece4e7cec8", "key": "payee_sim_day", "cell": "2026-10-25", "window_min": 180,
                "opened_at": "2026-11-06T14:30:00+06:00", "last_fired_at": "…", "observed": 30, "expected": 6e-05,
                "p_value": 8.3e-160, "surprise": 159.08, "reason": "poisson", "firing_runs": ["…"],
                "baseline_source": "prior", "payday_factor": 1.0, "attempt_ids": ["…"], "held": 19, "allowed": 11}],
 "campaigns": [{"campaign_id": "camp_5815ecd8fd", "opened_at": "…", "as_of": "…", "attempt_ids": ["…"], "senders": ["…"],
                "payees": ["…"], "tills": ["AG-0022"], "incident_ids": ["…"], "held": 19, "allowed": 11, "allowed_bdt": 71260.0,
                "synchrony": 0.3, "concentration": 10.0, "rank_score": 162.4,
                "evidence": [["att_…", "att_…", "payee_sim_day:2026-10-25"]],
                "payee_links": [{"payee": "acct_02300", "entity": "onboarding_agent:AG-0007", "kind": "onboarding_agent"}],
                "shared_entities": [{"entity": "payee_onboarding_agent:AG-0007", "kind": "payee_onboarding_agent",
                                     "payees": ["…"], "in_evidence": false}],
                "superseded_by": null}],
 "evaluation": {"source": "eval/results/campaign.json", "generated_at": "…", "seed_checksum": "…",
                "config": {"P_THRESHOLD": 1e-07}, "measures": {"time_to_flag_min": {"value": 13.27, "target": "<= 15.0", "status": "pass"}},
                "caveat": "…", "payee_note": "…", "incident_classes": {"fraud_dominant": 31},
                "incidents": [{"incident_id": "…", "incident_class": "fraud_dominant"}],
                "campaigns": [{"campaign_id": "ring_callcentre_2", "detected_campaign_id": "camp_5815ecd8fd",
                               "flag_ts": "…+06:00", "tenth_ts": "…", "time_to_flag_min": 0.37, "allowed_by_flag": 29720.0,
                               "cashed_out_by_flag": 0, "retained_by_flag": 29720.0, "retained_fraction": 1.0,
                               "future_allowed_after_flag": 41540.0, "precision": 1.0, "recall": 1.0, "victim_coverage": 1.0,
                               "payees_found": 3, "payees_named": 3, "payees_total": 3, "payee_overreach": null}]}}
```

**Detail** — one incident and what its map, timeline and graph draw (`CampaignIncident`): `incident`,
`campaigns` (every snapshot naming it, in id order; the console never picks one silently), `firings`
(same key and cell, at the incident's runs; counts only), and `attempts` (the incident's, plus every
attempt its campaigns and their evidence name; observable fields only, no label). An unknown or
malformed id is `404`.

| Field | Meaning |
|---|---|
| `shared_entities` | `payee_links` grouped by entity: one two or more of the campaign's payees share as of `as_of`, and whether an evidence triple names it. The view draws the ones no triple needed as dashed context, never as evidence |
| `superseded_by` | Set when a later snapshot holds every attempt of this one. The radar names a campaign after its earliest attempt, so a component that reached back in time left its earlier snapshot behind |
| `evaluation` | Eval-only, from generated truth: displayed, never passed to detection or ranking. `incidents[].incident_class` is computed with `radar_eval.incident_class`, and the builder fails if its counts disagree with `campaign.json` or if `campaign.json` was produced from other inputs |

**Missing or malformed fixture**: both routes answer `200` with `{"available": false, "reason": "…"}` (and
empty sections), the way `/v1/admin/audit` reports a Firestore it cannot reach. One unparsable file or a
section that does not match the schema makes the whole source unavailable; it never becomes a 500 or
zeros. Rebuild with `python tools/build_campaigns.py`; `--check` fails when stale.

### 2.6 `GET /v1/admin/cashout` and `GET /v1/admin/cashout/day/{date}` — built

The common point of cash-out on the campaign world. Both routes take the operator token and serve
`fixtures/cashout.json`, which `tools/build_cashout.py` writes by replaying the radar's cash-out rules
(`libs/radar/bhorosha_radar`: `cashout`, `cashout_rules`, `cashout_seeds`, through `eval/cashout_eval.py`'s own
functions) at every midnight of `data/seed-campaign`, and copying the evaluation from
`eval/results/cashout.json`. **No rule replay, Firestore read or Gemini call happens at request time.** The
fixture is validated once against `CashoutFixture` and kept in memory; a rebuilt file (new mtime or size) is read
again. Every timestamp carries `+06:00`. A **day** is the date of a 00:00 run, which closes the day before it.

**Whole** (`CashoutView`): the fixture as written, plus `available`.

```jsonc
{"available": true, "generated_at": "…",
 "source": {"seed_dir": "data/seed-campaign", "seed_checksum": "…", "input_checksums": {"transactions.jsonl": "…"},
            "eval_file": "eval/results/cashout.json", "eval_sha256": "…", "producer": "…",
            "timezone": "Asia/Dhaka (+06:00)", "synthetic": true},
 "config": {"TILL_REUSE_DAYS": 30, "TILL_REUSE_P_THRESHOLD": 0.001, "CLUSTER_P_THRESHOLD": 1e-07, "…": "…"},
 "tills": [{"id": "AG-0001", "district": "Sylhet", "lat": 24.848, "lon": 91.90752, "opened": "2026-03-09T08:00:00+06:00"}],
 "days": [{"date": "2026-10-23", "as_of": "2026-10-23T00:00:00+06:00", "seeds": 6, "open_tills": 40, "cashouts": 87,
           "till_flags": [{"id": "AG-0038", "seed_accounts": ["acct_02100", "…"], "accounts": 56, "expected": 0.2526,
                           "p_value": 0.000139, "first_seen_ts": "…", "last_seed_ts": "…"}],
           "clusters": ["clu_274dce9b4713", "clu_ec0cca9cc7b1"], "candidates": 2,
           "not_flagged": {"first_time_senders": 52, "pass_through": 50}}],
 "candidates": [{"acct": "acct_00415", "till": "AG-0038", "ts": "2026-10-09T16:00:46+06:00", "amount_bdt": 7030.0,
                 "filter": "pass_through", "source": "till_reuse", "first_time_senders": 1, "new_counterparties": 1,
                 "received_bdt": 780.0, "cashed_out_bdt": 7030.0, "pass_through_share": 9.01,
                 "first_day": "2026-10-23", "days": ["2026-10-23"]}],
 "not_flagged": {"pass_through": {"accounts": 131, "by_reason": {"no_new_counterparty": 129, "low_pass_through_share": 2}}},
 "clusters": [{"cluster_id": "clu_ec0cca9cc7b1", "mode": "replay", "first_day": "2026-10-23", "days": ["…"],
               "opened_at": "2026-10-19T15:55:23+06:00", "centre_lat": 22.69785, "centre_lon": 90.63207, "radius_km": 2.5,
               "window_start": "…", "window_end": "…", "tills": ["AG-0038"],
               "seed_cashouts": [{"txn_id": "txn_004691", "ts": "2026-10-19T15:09:59+06:00", "acct": "acct_02102",
                                  "till": "AG-0038", "lat": 22.69785, "lon": 90.63207, "amount_bdt": 8950.0}],
               "other_cashouts": [], "observed": 6, "expected": 0.075, "p_value": 2.3e-10, "baseline_source": "prior"}],
 "events": {"2026-10-23": [{"txn_id": "txn_004691", "ts": "2026-10-19T15:09:59+06:00", "acct": "acct_02102",
                            "till": "AG-0038", "lat": 22.69785, "lon": 90.63207, "amount_bdt": 8950.0, "kind": "seed"}]},
 "evaluation": {"source": "eval/results/cashout.json", "generated_at": "…", "world": "seed_campaign",
                "seed_checksum": "…", "config": {"…": "…", "HORIZON_DAYS": 7}, "caveat": "…",
                "measures": {"days_run": 36, "till_flags": {"precision": 0.9, "base_rate": 0.474}, "filters": {"…": "…"}},
                "candidates": [{"acct": "acct_00079", "filter": "pass_through", "first_day": "2026-10-30",
                                "outcome": "mule", "labelled": "mule", "confirmed_at": "2026-10-30T13:00:00+06:00",
                                "lead_days": 0.54}]}}
```

**One day** (`CashoutDayView`): `date`, `as_of`, `seeds`, `cashouts`, the `tills` open at `as_of`, that run's
`till_flags` and `not_flagged` counts, every cluster and candidate whose `days` include the date (full objects), and
that day's `events` (empty on a day with no flag and no cluster). A date that is not `YYYY-MM-DD` or not a calendar
date is `422`; a well-formed date with no daily run is `404`.

| Field | Meaning |
|---|---|
| `till_flags` | More confirmed mules (`seed_accounts`) cashed out at the till in the last `TILL_REUSE_DAYS` than its own volume (`accounts`) predicts at the network-wide share of seeds (`expected`), with `p_value` at most `TILL_REUSE_P_THRESHOLD`. A place to look, not a finding about the agent |
| `clusters` | `mode: "replay"`: the circle replayed over days already past with the seeds known at that midnight. `mode: "live"` would be one that fired as it happened; with the three-day confirmation lag none does on this world. `seed_cashouts` are the seed cash-outs it opened on; `other_cashouts` the rest of its members |
| `candidates` | Leads for an analyst, never verdicts: each account once per filter, as the first run that named it saw it, with every day a run listed it. `pass_through_share` is `cashed_out_bdt / received_bdt` over the lookback (null when nothing came in) |
| `events` | Kept only for days with a flag or a cluster: the cash-outs of the day the run closes, every seed cash-out a flag rests on, and each listed candidate's own cash-out. `kind` is the account as of that run: `seed` (confirmed), `candidate` (listed that day) or `ordinary`; `lat`/`lon` are the till's |
| `evaluation` | Eval-only, from generated truth: displayed, never passed to the rules. `candidates[].outcome` is `mule` (a labelled non-victim ring member, whenever it is confirmed: the evaluation's own test, so the console's count agrees with `cashout.md`) or `not_mule` (a victim or an unlabelled account); `confirmed_at` and `lead_days` sit beside it, and a `confirmed_at` after the last daily run means the analysts confirmed it after the world ends. The builder fails if `cashout.json` came from another seed, another config, or scored other candidates or days |

**Missing or malformed fixture**: both routes answer `200` with `{"available": false, "reason": "…"}`, as §2.5. Rebuild
with `python tools/build_cashout.py`; `--check` fails when stale.

---

## 3. What we deliberately do not add

* **No Gemini route of our own.** This console renders what the other components' models produced. A
  generated sentence between the analyst and the evidence is a liability, not a feature. The one place
  it could earn a slot is a drafted STR narrative — T2, and it needs four eyes anyway.
* **No write path at T0.** The only write in the whole design is the T1 disposition.
* **No new auth system at T0.** `X-Demo-User` as everywhere else; Firebase custom claims at T1.
