"""Load the seed world into BigQuery, Firestore (or the emulator) — one world for every module.

    python load_seed.py --seed-dir ../../data/seed --target local      # validate only
    python load_seed.py --seed-dir ../../data/seed --target bigquery   # dataset bhorosha_synth, WRITE_TRUNCATE
    python load_seed.py --seed-dir ../../data/seed --target firestore  # users/, demo_state/, transactions/ (personas + rings)
    FIRESTORE_EMULATOR_HOST=localhost:8080 python load_seed.py --target firestore   # same, into the emulator

Idempotent: every document has a fixed id and every BigQuery load truncates the table.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bhorosha_synth import schema as s  # noqa: E402
from bhorosha_synth.world import World  # noqa: E402
from bhorosha_graph.bundle import load_world_tables  # noqa: E402

DATASET = "bhorosha_synth"
PERSONAS = {
    s.RINA_ACCT: {"uid": "rina", "name_bn": "রিনা আক্তার", "name_en": "Rina Akter", "phone_masked": "017XXXXX412", "persona": "rina", "trusted_contact_uid": "rafiq", "p95_send_bdt": 5000},
    s.RAFIQ_ACCT: {"uid": "rafiq", "name_bn": "রফিক ইসলাম", "name_en": "Rafiq Islam", "phone_masked": "018XXXXX207", "persona": "rafiq", "trusted_contact_uid": None, "p95_send_bdt": 3000},
    s.RAHIMA_ACCT: {"uid": "rahima", "name_bn": "রহিমা বেগম", "name_en": "Rahima Begum", "phone_masked": "019XXXXX881", "persona": "rahima", "trusted_contact_uid": "rafiq", "p95_send_bdt": 2000},
    s.BENIGN_SIM_SWAP_ACCT: {"uid": "sumon", "name_bn": "সুমন মিয়া", "name_en": "Sumon Mia", "phone_masked": "016XXXXX550", "persona": "benign_new_phone", "trusted_contact_uid": None, "p95_send_bdt": 4000},
}
DEMO_STATE_DEFAULT = {"sim_swap": False, "call_active": False, "screen_share": False, "caller_in_contacts": False}


def _project() -> str:
    project = os.environ.get("RISK_MW_PROJECT_ID") or os.environ.get("GOOGLE_CLOUD_PROJECT") or ""
    if not project and "FIRESTORE_EMULATOR_HOST" not in os.environ:
        raise SystemExit("set RISK_MW_PROJECT_ID (or GOOGLE_CLOUD_PROJECT), or FIRESTORE_EMULATOR_HOST for the emulator")
    return project or "demo-bhorosha"


def _demo_scope(world: World) -> tuple[set[str], tuple[dict, ...]]:
    """Accounts and transactions the app needs: personas plus every labelled ring."""
    accts = set(PERSONAS) | {l["acct_id"] for l in world.labels}
    txns = tuple(t for t in world.transactions if t["ring_id"] or t["from_acct"] in PERSONAS or t["to_acct"] in PERSONAS)
    return accts, txns


def load_local(world: World, seed_dir: Path) -> dict:
    accts, txns = _demo_scope(world)
    checksum = (seed_dir / "CHECKSUM").read_text(encoding="utf-8").strip()
    if checksum != world.checksum():
        raise SystemExit("CHECKSUM does not match the JSONL files; regenerate the seed")
    return {"target": "local", "checksum": checksum, "tables": {n: len(r) for n, r in world.tables().items()}, "demo_accounts": len(accts), "demo_transactions": len(txns)}


def load_bigquery(world: World, seed_dir: Path) -> dict:
    from google.cloud import bigquery

    client = bigquery.Client(project=_project())
    client.create_dataset(bigquery.Dataset(f"{client.project}.{DATASET}"), exists_ok=True)
    loaded = {}
    for name in s.FILE_NAMES:
        table = name.removesuffix(".jsonl")
        config = bigquery.LoadJobConfig(source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON, autodetect=True, write_disposition="WRITE_TRUNCATE")
        with (seed_dir / name).open("rb") as handle:
            job = client.load_table_from_file(handle, f"{client.project}.{DATASET}.{table}", job_config=config)
        job.result()
        loaded[table] = int(job.output_rows or 0)
    return {"target": "bigquery", "dataset": f"{client.project}.{DATASET}", "rows": loaded}


def load_firestore(world: World, seed_dir: Path) -> dict:
    from google.cloud import firestore

    client = firestore.Client(project=_project())
    accts, txns = _demo_scope(world)
    account_rows = {a["acct_id"]: a for a in world.accounts}
    batch, writes = client.batch(), 0

    def put(collection: str, doc_id: str, data: dict) -> None:
        nonlocal batch, writes
        batch.set(client.collection(collection).document(doc_id), data)
        writes += 1
        if writes % 400 == 0:
            batch.commit()
            batch = client.batch()

    for acct_id, persona in PERSONAS.items():
        put("users", persona["uid"], {**persona, "acct_id": acct_id, "district": account_rows[acct_id]["district"], "seed_checksum": world.checksum()})
        put("demo_state", persona["uid"], {**DEMO_STATE_DEFAULT, "persona": persona["persona"]})
    for acct_id in sorted(accts):
        row = account_rows[acct_id]
        labels = [l for l in world.labels if l["acct_id"] == acct_id]
        put("accounts", acct_id, {**row, "labels": labels})
    for t in txns:
        put("transactions", t["txn_id"], {**t, "status": "done"})
    batch.commit()
    return {"target": "firestore", "project": client.project, "users": len(PERSONAS), "demo_state": len(PERSONAS), "accounts": len(accts), "transactions": len(txns)}


LOADERS = {"local": load_local, "bigquery": load_bigquery, "firestore": load_firestore}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seed-dir", type=Path, default=Path(__file__).resolve().parents[2] / "data" / "seed")
    parser.add_argument("--target", choices=tuple(LOADERS), default="local")
    args = parser.parse_args(argv)
    world = load_world_tables(args.seed_dir)
    if world.campaign is not None and args.target != "local":
        # The campaign world is the radar's offline world; loading it would truncate the demo tables.
        raise SystemExit("the campaign world is offline only: validate it with --target local; load the demo seed to the cloud")
    print(json.dumps(LOADERS[args.target](world, args.seed_dir), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
