"""Client for Case Zero, the agentic investigator that /v1/investigate fronts.

Case Zero is its own Cloud Run service. This module speaks its two-step API (start a case, then
watch it) and translates what it sends into the shapes risk-mw's frozen contract promises:
the CaseReport JSON, and the {"step": ...} events the console and the app already consume.
It raises InvestigatorUnavailable for anything that means "try the stub instead".
"""

from __future__ import annotations

import json
import logging
from collections.abc import AsyncIterator
from typing import Any

import httpx

log = logging.getLogger(__name__)

JSON_TIMEOUT = httpx.Timeout(10.0, connect=5.0)
# Case Zero pings an idle stream every few seconds, so a long silence means the service is gone.
STREAM_TIMEOUT = httpx.Timeout(120.0, connect=5.0)
NOT_FOUND = 404


class InvestigatorUnavailable(RuntimeError):
    """Case Zero is busy, down or answered something unusable; the caller falls back to the stub."""


class UnknownCase(LookupError):
    """Case Zero has no case with that id (it keeps cases in memory, so a restart forgets them)."""


async def sse_events(lines: AsyncIterator[str]) -> AsyncIterator[dict[str, Any]]:
    """Decode a text/event-stream into the JSON objects in its data fields.

    Comments (pings), ids and event names are ignored: Case Zero repeats the event type inside the
    JSON. A frame that is not JSON is skipped, not fatal.
    """
    data: list[str] = []
    async for line in lines:
        if line:
            if line.startswith("data:"):
                data.append(line[5:].removeprefix(" "))
            continue
        if not data:
            continue
        frame, data = "\n".join(data), []
        try:
            event = json.loads(frame)
        except json.JSONDecodeError:
            log.warning("skipping a malformed investigator frame: %.80s", frame)
            continue
        if isinstance(event, dict):
            yield event


class CaseZeroClient:
    def __init__(self, base_url: str, *, transport: httpx.BaseTransport | httpx.AsyncBaseTransport | None = None) -> None:
        self._base = base_url.rstrip("/")
        self._transport = transport

    # --- plain requests ------------------------------------------------------------------------

    def _request(self, method: str, path: str, **kwargs: Any) -> httpx.Response:
        try:
            with httpx.Client(base_url=self._base, timeout=JSON_TIMEOUT, transport=self._transport) as http:
                return http.request(method, path, **kwargs)
        except httpx.HTTPError as exc:
            raise InvestigatorUnavailable(f"{type(exc).__name__}: {exc}") from exc

    def start(self, acct_id: str) -> str:
        """Start an investigation and return Case Zero's case id."""
        response = self._request("POST", "/api/investigations", json={"acct_id": acct_id})
        if response.status_code != httpx.codes.ACCEPTED:
            raise InvestigatorUnavailable(f"start answered {response.status_code}")
        case_id = response.json().get("case_id")
        if not isinstance(case_id, str) or not case_id:
            raise InvestigatorUnavailable("start returned no case id")
        return case_id

    def status(self, case_id: str) -> dict[str, Any]:
        response = self._request("GET", f"/api/investigations/{case_id}")
        if response.status_code == NOT_FOUND:
            raise UnknownCase(case_id)
        if response.status_code != httpx.codes.OK:
            raise InvestigatorUnavailable(f"status answered {response.status_code}")
        return response.json()

    def contract(self, case_id: str) -> dict[str, Any] | None:
        """The finished case in risk-mw's CaseReport shape, or None while it is not final."""
        response = self._request("GET", f"/api/cases/{case_id}/contract")
        if response.status_code == NOT_FOUND:
            return None
        if response.status_code != httpx.codes.OK:
            raise InvestigatorUnavailable(f"contract answered {response.status_code}")
        return response.json()

    # --- the live stream -----------------------------------------------------------------------

    async def steps(self, case_id: str) -> AsyncIterator[dict[str, Any]]:
        """Case Zero's events for one case as {"step": plan|tool|evidence|done|error} dictionaries.

        Evidence is taken from the finished case, so its row ids are the real transaction ids
        Case Zero resolved, not the call ids the live stream can only cite.
        """
        seed: str | None = None
        score: float | None = None
        try:
            async with httpx.AsyncClient(base_url=self._base, timeout=STREAM_TIMEOUT, transport=self._transport) as http:
                async with http.stream("GET", f"/api/investigations/{case_id}/events") as response:
                    if response.status_code != httpx.codes.OK:
                        yield {"step": "error", "text": f"investigator answered {response.status_code}"}
                        return
                    async for event in sse_events(response.aiter_lines()):
                        kind = event.get("type")
                        if kind == "run_started":
                            seed = event.get("seed")
                            yield {"step": "plan", "text": f"Investigating {seed} as of {event.get('as_of')}"}
                        elif kind == "score":
                            yield {"step": "tool", "name": "score", "args": {"acct_id": seed}}
                        elif kind == "tool_call":
                            yield {"step": "tool", "name": event.get("name"), "args": event.get("args") or {}}
                        elif kind == "report":
                            score = (event.get("report") or {}).get("model_score")
                        elif kind == "error":
                            yield {"step": "error", "text": str(event.get("message") or "investigation failed")}
                        elif kind == "done":
                            async for step in self._closing_steps(http, case_id, score):
                                yield step
                            return
                    yield {"step": "error", "text": "the investigation stream ended before the case finished"}
        except httpx.HTTPError as exc:
            log.warning("investigator stream for %s failed: %s", case_id, exc)
            yield {"step": "error", "text": "lost the connection to the investigator"}

    async def _closing_steps(self, http: httpx.AsyncClient, case_id: str, score: float | None) -> AsyncIterator[dict[str, Any]]:
        confidence = score
        try:
            response = await http.get(f"/api/cases/{case_id}/contract")
            if response.status_code == httpx.codes.OK:
                contract = response.json()
                for item in contract.get("evidence") or ():
                    yield {"step": "evidence", "row_id": item["row_id"], "text": item["claim"]}
                confidence = contract.get("confidence", score)
        except (httpx.HTTPError, KeyError, ValueError) as exc:
            log.warning("could not read the finished case %s: %s", case_id, exc)
        yield {"step": "done", "confidence": confidence if confidence is not None else 0.0}
