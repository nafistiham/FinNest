"""The generated world as immutable tables, plus a content checksum."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass

from bhorosha_synth.schema import CAMPAIGN_FILE_NAMES, FILE_NAMES, CampaignConfig, WorldConfig

Rows = tuple[dict, ...]


@dataclass(frozen=True)
class World:
    config: WorldConfig
    customers: Rows
    accounts: Rows
    sims: Rows
    sim_events: Rows
    devices: Rows
    device_links: Rows
    agents: Rows
    merchants: Rows
    transactions: Rows
    labels: Rows
    campaign: CampaignConfig | None = None  # set only on the campaign world
    attempts: Rows = ()
    bursts: Rows = ()

    def tables(self) -> dict[str, Rows]:
        """File name -> rows, in FILE_NAMES order; the campaign world adds CAMPAIGN_FILE_NAMES after them."""
        by_attr = {
            "customers.jsonl": self.customers,
            "accounts.jsonl": self.accounts,
            "sims.jsonl": self.sims,
            "sim_events.jsonl": self.sim_events,
            "devices.jsonl": self.devices,
            "device_links.jsonl": self.device_links,
            "agents.jsonl": self.agents,
            "merchants.jsonl": self.merchants,
            "transactions.jsonl": self.transactions,
            "labels.jsonl": self.labels,
            "attempts.jsonl": self.attempts,
            "bursts.jsonl": self.bursts,
        }
        names = FILE_NAMES + (CAMPAIGN_FILE_NAMES if self.campaign is not None else ())
        return {name: by_attr[name] for name in names}

    def checksum(self) -> str:
        digest = hashlib.sha256()
        for name, rows in self.tables().items():
            digest.update(name.encode())
            for row in rows:
                digest.update(json.dumps(row, sort_keys=True, ensure_ascii=False).encode("utf-8"))
        return digest.hexdigest()
