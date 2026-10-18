"""Great-circle distance between two points, for till-to-till distances."""
from __future__ import annotations

import math

from .config import EARTH_RADIUS_KM


def is_valid_point(lat, lon) -> bool:
    """A finite latitude in [-90, 90] and longitude in [-180, 180]; booleans and missing values are not points."""
    numbers = all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) for v in (lat, lon))
    return numbers and -90 <= lat <= 90 and -180 <= lon <= 180


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Distance in kilometres along the sphere of mean Earth radius; raises ValueError for a point off the globe."""
    if not (is_valid_point(lat1, lon1) and is_valid_point(lat2, lon2)):
        raise ValueError(f'invalid point: ({lat1}, {lon1}) or ({lat2}, {lon2})')
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    half_dphi, half_dlambda = math.radians(lat2 - lat1) / 2, math.radians(lon2 - lon1) / 2
    h = math.sin(half_dphi) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(half_dlambda) ** 2
    return 2 * EARTH_RADIUS_KM * math.asin(min(1.0, math.sqrt(h)))
