"""
06_query_mrnf_events.py - forest interventions, fires and other disturbances recorded by the MRNF under each plot

Author:    João Paulo Czarnecki de Liz (developer)
Co-author: Claude (Anthropic), AI coding assistant
Licence:   MIT (see LICENSE)

Queries the public MRNF web feature service (WFS) for the polygons of three layers that intersect the 11.28 m
plot circle, and keeps the share of the circle each polygon covers:
  ca_interv_for_close_scale     harvests (ORIGINE: clearcut, CPRS, ...) and partial cuts / tending (PERTURB)
  ca_feu_close_scale            fires
  ca_perturb_autre_close_scale  windthrow, insect outbreaks, dieback, ice storm, ...
A pair (plot, satellite sample) is later discarded when one of these events falls between the ALS flight and the
satellite date. One JSON per plot is cached, so the ~10,000 queries resume after an interruption.

Input   data/plot_als_metrics.csv (or data/derived/plot_tiles.csv)
Output  data/derived/plot_mrnf_events.csv   (plot_id, layer, exercice, origine, an_origine, perturb, an_perturb, overlap)
Run     python -I scripts/06_query_mrnf_events.py        (~1 h with 6 parallel requests; WORKERS=6 by default)
"""
import json
import math
import os
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import pandas as pd
from shapely import affinity
from shapely.geometry import Point, shape

ROOT = os.environ.get("EXERCISE_ROOT", ".")
OUT = os.path.join(ROOT, "data", "derived"); CACHE = os.path.join(OUT, "mrnf_cache")
os.makedirs(CACHE, exist_ok=True)
WFS = "https://geoegl.msp.gouv.qc.ca/ws/mffpecofor.fcgi"
LAYERS = ["ca_interv_for_close_scale", "ca_feu_close_scale", "ca_perturb_autre_close_scale"]
FIELDS = ["exercice", "origine", "an_origine", "perturb", "an_perturb", "classe", "origine_desc", "perturb_desc"]
PLOT_RADIUS_M = 11.28
WORKERS = int(os.environ.get("WORKERS", "6"))


def plot_circle(lon, lat):
    """11.28 m circle in lon/lat degrees (an ellipse in degrees, a circle on the ground)."""
    r = PLOT_RADIUS_M / 111_320
    return affinity.scale(Point(lon, lat).buffer(r, 32), xfact=1 / math.cos(math.radians(lat)), yfact=1)


def get_json(params):
    url = f"{WFS}?{urllib.parse.urlencode(params)}"
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                return json.loads(r.read().decode("utf-8"))
        except Exception:  # noqa: BLE001 - busy server or bad gateway: wait and retry
            time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"no answer from the WFS for {params.get('typeNames')}")


def query_plot(pid, lon, lat):
    path = os.path.join(CACHE, f"{pid}.json")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    circle = plot_circle(lon, lat)
    minx, miny, maxx, maxy = circle.bounds
    events = []
    for layer in LAYERS:
        js = get_json({"service": "WFS", "version": "2.0.0", "request": "GetFeature", "typeNames": f"ms:{layer}",
                       "outputFormat": "geojson", "bbox": f"{miny},{minx},{maxy},{maxx},urn:ogc:def:crs:EPSG::4326"})
        for f in js.get("features", []):
            geom = shape(f["geometry"])
            if not geom.is_valid:
                geom = geom.buffer(0)
            ov = geom.intersection(circle).area / circle.area
            if ov > 0:
                events.append({"layer": layer, **{k: f["properties"].get(k) for k in FIELDS}, "overlap": round(ov, 3)})
    out = {"plot_id": int(pid), "events": events}
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(out, fh)
    return out


def main():
    src = os.path.join(ROOT, "data", "plot_als_metrics.csv")
    if not os.path.exists(src):
        src = os.path.join(OUT, "plot_tiles.csv")
    plots = pd.read_csv(src)[["plot_id", "longitude", "latitude"]].dropna()
    print(f"{len(plots)} plots; {len(os.listdir(CACHE))} already cached", flush=True)
    t0 = time.time()
    with ThreadPoolExecutor(WORKERS) as ex:
        res = list(ex.map(lambda r: query_plot(int(r.plot_id), r.longitude, r.latitude), plots.itertuples()))
    rows = [{"plot_id": r["plot_id"], **e} for r in res for e in r["events"]]
    ev = pd.DataFrame(rows, columns=["plot_id", "layer"] + FIELDS + ["overlap"])
    ev.to_csv(os.path.join(OUT, "plot_mrnf_events.csv"), index=False)
    print(f"{len(ev)} events on {ev.plot_id.nunique()} plots ({(time.time() - t0) / 60:.0f} min) -> {OUT}/plot_mrnf_events.csv")


if __name__ == "__main__":
    main()
