"""Three non-LLM baselines the agent must beat."""

from __future__ import annotations

from bhorosha_graph import tools as gt

from case_zero.world import World

ENTITY_KINDS = ("device:", "sim:", "nid:", "phone:")


def bfs2(world: World, seed: str, as_of: str) -> set[str]:
    rows = gt.neighbours(world.bundle, seed, 2, as_of, limit=100_000)["neighbours"]
    return {seed} | {r["acct_id"] for r in rows}


def score_only(world: World, seed: str, as_of: str, threshold: float = 0.5) -> set[str]:
    return {a for a in bfs2(world, seed, as_of) if world.score_at(a, as_of)["probability"] >= threshold}


def shared_entity_components(world: World, seed: str) -> set[str]:
    links, seen, frontier = world.bundle.links, {seed}, [seed]
    while frontier:
        node = frontier.pop()
        for entity in links.neighbors(node) if node in links else ():
            if not entity.startswith(ENTITY_KINDS):
                continue
            for acct in links.neighbors(entity):
                if acct not in seen:
                    seen.add(acct)
                    frontier.append(acct)
    return seen
