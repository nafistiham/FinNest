"""The findable part of a ring: members any method could reach from the seed at `as_of`.

Reachable = within 3 money hops (either direction) or sharing a device, SIM, NID or phone
with the seed at that time. Recall against this ceiling separates the agent's misses from
members that no method could see from that seed.
"""

from __future__ import annotations

from bhorosha_graph import tools as gt

from case_zero.world import World

MONEY_HOPS = 3
IDENTITY_KINDS = ("device:", "sim:", "nid:", "phone:")


def findable(world: World, seed: str, as_of: str, truth: set[str], hops: int = MONEY_HOPS) -> set[str]:
    rows = gt.neighbours(world.bundle, seed, hops, as_of, limit=1_000_000)["neighbours"]
    reach = {seed} | {r["acct_id"] for r in rows}
    for entity in world.entity_links(seed, as_of):
        if entity.startswith(IDENTITY_KINDS):
            reach |= world.entity_holders(entity, as_of)
    return set(truth) & reach
