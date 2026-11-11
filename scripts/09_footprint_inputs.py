"""
09_footprint_inputs.py - inputs for checking ICESat-2 / GEDI against airborne lidar (ALS) on the exact ground of
each satellite sample, in one region: the UPE 14-15 study area (data/study_area/, 12,644 km2, ALS 2017-2018).

Author:    João Paulo Czarnecki de Liz (developer)
Co-author: Claude (Anthropic), AI coding assistant
Licence:   MIT (see LICENSE)

Two passes:
  --tiles-only  lists the ALS tiles that hold the region's plots (data/derived/why/tiles_needed.csv), to download
                them with   TILE_LIST=data/derived/why/tiles_needed.csv Rscript scripts/02_download_laz.R
  (default)     once the tiles are on disk, builds the tables below.

What it builds (all in data/derived/why/):
  plots_upe.csv      one row per PEP plot inside the study area that has ALS metrics: plot ALS metrics
                     (data/plot_als_metrics.csv, 11.28 m plots), ALS tile and acquisition date, forest type
                     from the field tree tally closest to the satellite years, field top height, and MRNF
                     disturbances recorded after the ALS flight.
  tiles_upe.csv      the 1 km ALS tiles that hold those plots (path, EPSG, extent, acquisition dates).
  samples_gedi.csv   every downloaded GEDI L2A shot whose 25 m footprint lies wholly inside one of those tiles,
                     with the footprint centre in the tile CRS, nearest plot and post-ALS disturbance flags.
                     No quality filters applied here (leaf-off, sensitivity), so their effect can be tested.
  samples_atl08.csv  same for ICESat-2 ATL08 100 m segments (all beams, snow flag kept), with the along-track
                     direction so the 100 m x 14 m segment rectangle can be drawn in the tile CRS.
  mrnf_cache/        MRNF harvest / fire / other-disturbance polygons per tile (public WFS, cached).

Forest type (MFFP convention, live basal area of trees >= 9.1 cm dbh): R softwood >= 75 %, F hardwood >= 75 %,
M mixed otherwise; "Open / regenerating" when live basal area < 4 m2/ha.

Inputs (read-only)
  data/study_area/upe1415_study_area.shp       the region (provided)
  data/raw/PEP.gpkg                            PEP plots and tree tally (Données Québec; or set PEP_GPKG)
  data/plot_als_metrics.csv                    plot ALS metrics and tile names (provided; or your own
                                               data/derived/plot_als_metrics_full.csv from step 3)
  data/plot_mrnf_events.csv                    MRNF events under each plot (provided; or yours from step 6)
  data/derived/why/{gedi02a,atl08}.csv         satellite samples over the region, all of them, from
                                               05_get_spaceborne_lidar.py with the study area as polygon
  data/raw/laz/*.LAZ                           the region's ALS tiles (only their headers are read here)
  MRNF WFS                                     disturbance polygons per tile (public; cached in mrnf_cache/)

Run   python -I scripts/09_footprint_inputs.py --tiles-only      (seconds)
      python -I scripts/09_footprint_inputs.py                   (~10 min the first time, WFS cached after)
"""
from __future__ import annotations

import json
import os
import sqlite3
import struct
import sys
import time
import urllib.parse
import urllib.request
import warnings

import geopandas as gpd
import numpy as np
import pandas as pd
from pyproj import Transformer
from shapely.geometry import Point, Polygon, shape

warnings.filterwarnings("ignore")
ROOT = os.environ.get("EXERCISE_ROOT", ".")
OUT = os.environ.get("WHY_DIR", os.path.join(ROOT, "data", "derived", "why"))
DAT = os.environ.get("WHY_SAT_DIR", OUT)                 # where gedi02a.csv and atl08.csv of the region are
os.makedirs(os.path.join(OUT, "mrnf_cache"), exist_ok=True)

PEP = os.environ.get("PEP_GPKG", os.path.join(ROOT, "data", "raw", "PEP.gpkg"))
LAZ = os.environ.get("LAZ_DIR", os.path.join(ROOT, "data", "raw", "laz"))
AREA = os.path.join(ROOT, "data", "study_area", "upe1415_study_area.shp")
_own = os.path.join(ROOT, "data", "derived", "plot_als_metrics_full.csv")
ALS_TABLE = _own if os.path.exists(_own) else os.path.join(ROOT, "data", "plot_als_metrics.csv")
_ev = os.path.join(ROOT, "data", "derived", "plot_mrnf_events.csv")
EVENTS = _ev if os.path.exists(_ev) else os.path.join(ROOT, "data", "plot_mrnf_events.csv")
TILES_ONLY = "--tiles-only" in sys.argv
WFS = "https://geoegl.msp.gouv.qc.ca/ws/mffpecofor.fcgi"
LAYERS = ["ca_interv_for_close_scale", "ca_feu_close_scale", "ca_perturb_autre_close_scale"]

GEDI_R = 12.5            # GEDI footprint radius (m)
SEG_HALF_L, SEG_HALF_W = 50.0, 7.0   # ATL08 segment: 100 m along track x ~14 m (footprint width)
SOFTWOOD = {"SAB", "EPN", "EPB", "EPR", "EPO", "PIG", "PIB", "PIR", "PIS", "PRU", "THO", "MEL", "MEH", "MEJ", "MEU"}
LIVE = {"10", "12", "30", "32", "40", "42", "50", "52"}   # PEP etat codes for live trees
ALS_METRICS = ["pt_density_m2", "zmax", "zmean", "zq25", "zq50", "zq75", "zq90", "zq95", "pzabove2", "pzabove5",
               "canopy_cover_2m_fr", "p_overstory_10plus", "zsd"]


def log(*a):
    print(*a, flush=True)


# ---------------------------------------------------------------- plots in the study area -------------------
area = gpd.read_file(AREA).to_crs(2950)              # NAD83(CSRS) / Quebec Lambert
pl = gpd.read_file(PEP, layer="placette").to_crs(area.crs)
pl = gpd.sjoin(pl, area[["geometry"]], predicate="within").drop(columns="index_right")
pl["plot_id"] = pl.id_pe.astype(np.int64)
als = pd.read_csv(ALS_TABLE)
if "status" in als.columns:
    als = als[als.status == "ok"]
als = als[als.plot_id.isin(pl.plot_id)].copy()
if "tile_file_name" not in als.columns:
    als["tile_file_name"] = als.NOM_TUILE + ".LAZ"
metrics = [m for m in ALS_METRICS if m in als.columns]
plots = pl[["plot_id", "id_pe", "geometry"]].merge(
    als[["plot_id", "latitude", "longitude", "CODE_EPSG", "DATES_ACQUISITION", "tile_file_name"] + metrics], on="plot_id")
plots["x2950"], plots["y2950"] = plots.geometry.x, plots.geometry.y
plots["als_date"] = plots.DATES_ACQUISITION.str.split(",").str[0]
plots["als_date_last"] = plots.DATES_ACQUISITION.str.split(",").str[-1]
log(f"{len(pl)} PEP plots in the area, {len(plots)} with ALS metrics ({ALS_TABLE})")
if TILES_ONLY:
    need = plots[["tile_file_name"]].drop_duplicates()
    need.to_csv(os.path.join(OUT, "tiles_needed.csv"), index=False)
    log(f"{len(need)} tiles listed in {os.path.join(OUT, 'tiles_needed.csv')}")
    sys.exit(0)

# ---------------------------------------------------------------- field: forest type + top height ----------
con = sqlite3.connect(PEP)
ids = "','".join(plots.id_pe)
mes = pd.read_sql(f"select id_pe, id_pe_mes, no_mes, date_sond from placette_mes where id_pe in ('{ids}')", con)
mes["field_year"] = mes.date_sond.str[:4].astype(int)
# measurement closest to the satellite years: the latest one from 2015 on, else the latest available
mes = mes.sort_values(["id_pe", "no_mes"])
pick = mes[mes.field_year >= 2015].groupby("id_pe").tail(1)
pick = pd.concat([pick, mes[~mes.id_pe.isin(pick.id_pe)].groupby("id_pe").tail(1)])
tr = pd.read_sql(f"select id_pe_mes, etat, essence, dhp, st_ha from dendro_arbres where id_pe in ('{ids}')", con)
tr = tr[tr.id_pe_mes.isin(pick.id_pe_mes) & tr.etat.isin(LIVE)]
tr["soft"] = tr.essence.isin(SOFTWOOD)
ba = tr.groupby("id_pe_mes").agg(ba_live=("st_ha", "sum"), n_live=("st_ha", "size"))
ba["ba_soft"] = tr[tr.soft].groupby("id_pe_mes").st_ha.sum()
ba["ba_soft"] = ba.ba_soft.fillna(0)
dom = tr.groupby(["id_pe_mes", "essence"]).st_ha.sum().reset_index().sort_values("st_ha") \
    .groupby("id_pe_mes").tail(1).set_index("id_pe_mes").essence
ba["dom_species"] = dom
ba["soft_share"] = ba.ba_soft / ba.ba_live
et = pd.read_sql(f"select id_pe_mes, etat, haut_arbre from dendro_arbres_etudes where id_pe in ('{ids}')", con)
et = et[et.id_pe_mes.isin(pick.id_pe_mes) & et.etat.isin(LIVE) & et.haut_arbre.notna()]
et["h"] = et.haut_arbre / 10.0                                   # decimetres -> m
top = et.sort_values("h").groupby("id_pe_mes").h.apply(lambda v: v.tail(3).mean()).rename("field_htop")
hmax = et.groupby("id_pe_mes").h.max().rename("field_hmax")
nh = et.groupby("id_pe_mes").h.size().rename("field_n_heights")
fld = pick.set_index("id_pe_mes").join([ba, top, hmax, nh]).reset_index()


def ftype(r):
    if pd.isna(r.ba_live) or r.ba_live < 4:
        return "Open / regenerating"
    if r.soft_share >= 0.75:
        return "Softwood"
    if r.soft_share <= 0.25:
        return "Hardwood"
    return "Mixed"


fld["forest_type"] = fld.apply(ftype, axis=1)
plots = plots.merge(fld[["id_pe", "field_year", "no_mes", "ba_live", "soft_share", "dom_species", "forest_type",
                         "field_htop", "field_hmax", "field_n_heights"]], on="id_pe", how="left")
log(plots.forest_type.value_counts().to_dict())

# ---------------------------------------------------------------- disturbance after the ALS flight ----------
ev = pd.read_csv(EVENTS)
ev = ev[ev.plot_id.isin(plots.plot_id) & (ev.overlap >= 0.5)].copy()
ev["year"] = ev.an_perturb.fillna(ev.an_origine).fillna(ev.exercice)
ev = ev.merge(plots[["plot_id", "als_date"]], on="plot_id")
ev = ev[ev.year >= ev.als_date.str[:4].astype(int)]          # same year counted: it may postdate the flight
ev["kind"] = np.where(ev.layer == "ca_feu_close_scale", "fire",
                      np.where(ev.layer == "ca_interv_for_close_scale",
                               np.where(ev.origine.notna(), "harvest (stand-replacing)", "partial cut / tending"),
                               "other natural"))
post = ev.groupby("plot_id").agg(post_als_event=("kind", lambda k: "; ".join(sorted(set(k)))),
                                 post_als_year=("year", "min"))
plots = plots.merge(post, on="plot_id", how="left")
plots["post_als_event"] = plots.post_als_event.fillna("none")
log("plots disturbed after ALS:", (plots.post_als_event != "none").sum())

# ---------------------------------------------------------------- tiles ------------------------------------
def las_header(path):
    """Point count and extent from the LAS/LAZ public header (the header of a LAZ file is not compressed)."""
    with open(path, "rb") as fh:
        h = fh.read(255)
    minor = h[25]
    n = struct.unpack("<I", h[107:111])[0]
    if minor >= 4 and n == 0:
        n = struct.unpack("<Q", h[247:255])[0]
    xmax, xmin, ymax, ymin = struct.unpack("<4d", h[179:211])
    return n, xmin, xmax, ymin, ymax


tiles = plots[["tile_file_name", "CODE_EPSG", "DATES_ACQUISITION"]].drop_duplicates("tile_file_name").copy()
tiles["path"] = [os.path.abspath(os.path.join(LAZ, f)) for f in tiles.tile_file_name]
missing = int((~tiles.path.map(os.path.exists)).sum())
if missing:
    log(f"WARNING: {missing} of {len(tiles)} tiles are not in {LAZ}; their plots and samples are left out")
tiles = tiles[tiles.path.map(os.path.exists)].copy()
hdr = [las_header(p) for p in tiles.path]
for k, c in enumerate(["hdr_npoints", "hdr_xmin", "hdr_xmax", "hdr_ymin", "hdr_ymax"]):
    tiles[c] = [h[k] for h in hdr]
tiles["empirical_density_pts_m2"] = tiles.hdr_npoints / ((tiles.hdr_xmax - tiles.hdr_xmin) * (tiles.hdr_ymax - tiles.hdr_ymin))
plots = plots[plots.tile_file_name.isin(tiles.tile_file_name)]
tiles["als_date"] = tiles.DATES_ACQUISITION.str.split(",").str[0]
log(f"{len(tiles)} tiles, {tiles.hdr_npoints.sum() / 1e9:.2f} G points")

# ---------------------------------------------------------------- satellite samples inside tiles -----------
TR = {e: Transformer.from_crs(4326, int(e), always_xy=True) for e in tiles.CODE_EPSG.unique()}


def to_tile_xy(d, epsg):
    return TR[epsg].transform(d.lon.values, d.lat.values)


def assign(d, kind):
    """Return the rows of d whose whole footprint lies inside a tile, with tile id and tile-CRS coordinates."""
    out = []
    for epsg, tg in tiles.groupby("CODE_EPSG"):
        x, y = to_tile_xy(d, epsg)
        dd = d.assign(x_tile=x, y_tile=y)
        if kind == "atl08":
            ux, uy = dd[f"ux_{epsg}"].values, dd[f"uy_{epsg}"].values
            # half-extent of the rotated rectangle along x and y
            ex = np.abs(ux) * SEG_HALF_L + np.abs(uy) * SEG_HALF_W
            ey = np.abs(uy) * SEG_HALF_L + np.abs(ux) * SEG_HALF_W
        else:
            ex = ey = np.full(len(dd), GEDI_R)
        for t in tg.itertuples():
            m = (x - ex >= t.hdr_xmin + 1) & (x + ex <= t.hdr_xmax - 1) & (y - ey >= t.hdr_ymin + 1) & (y + ey <= t.hdr_ymax - 1)
            if m.any():
                s = dd[m].copy()
                s["tile_file_name"], s["tile_epsg"] = t.tile_file_name, int(epsg)
                if kind == "atl08":
                    s["ux"], s["uy"] = s[f"ux_{epsg}"], s[f"uy_{epsg}"]
                out.append(s)
    r = pd.concat(out, ignore_index=True)
    return r.drop(columns=[c for c in r.columns if c.startswith(("ux_", "uy_"))])


# GEDI L2A, no filters
g = pd.read_csv(os.path.join(DAT, "gedi02a.csv"))
g = g[(g.lon > -80) & (g.lat > 44)]
gs = assign(g, "gedi")
log(f"GEDI L2A shots inside tiles: {len(gs)} (of {len(g)})")

# ATL08: along-track direction from neighbouring segments of the same beam and date, in each tile CRS
a = pd.read_csv(os.path.join(DAT, "atl08.csv"))
a["date"] = a.time_ns.str[:10]
a = a.sort_values(["rgt", "cycle", "gt", "date", "segment_id_beg"]).reset_index(drop=True)
for epsg in tiles.CODE_EPSG.unique():
    x, y = to_tile_xy(a, epsg)
    a["_x"], a["_y"] = x, y
    grp = a.groupby(["rgt", "cycle", "gt", "date"])
    dx = grp._x.shift(-1) - grp._x.shift(1)
    dy = grp._y.shift(-1) - grp._y.shift(1)
    dx = dx.fillna(grp._x.shift(-1) - a._x).fillna(a._x - grp._x.shift(1))
    dy = dy.fillna(grp._y.shift(-1) - a._y).fillna(a._y - grp._y.shift(1))
    L = np.hypot(dx, dy)
    ok = (L > 0) & (L < 500)                         # neighbours more than 500 m away are another stretch
    a[f"ux_{epsg}"] = np.where(ok, dx / L, np.nan)
    a[f"uy_{epsg}"] = np.where(ok, dy / L, np.nan)
    # isolated segments: use the median direction of their beam on that date
    for c in (f"ux_{epsg}", f"uy_{epsg}"):
        a[c] = a[c].fillna(a.groupby(["rgt", "cycle", "gt", "date"])[c].transform("median"))
a = a.drop(columns=["_x", "_y"])
a = a[a[[c for c in a.columns if c.startswith("ux_")]].notna().all(axis=1)]
as_ = assign(a, "atl08")
log(f"ATL08 segments inside tiles: {len(as_)} (of {len(a)})")

# ---------------------------------------------------------------- nearest plot -----------------------------
t2950 = Transformer.from_crs(4326, 2950, always_xy=True)
pp = gpd.GeoDataFrame(plots[["plot_id", "forest_type"]], geometry=gpd.points_from_xy(plots.x2950, plots.y2950), crs=2950)
for s in (gs, as_):
    x, y = t2950.transform(s.lon.values, s.lat.values)
    s["x2950"], s["y2950"] = x, y
    sp = gpd.GeoDataFrame({"row": np.arange(len(s))}, geometry=gpd.points_from_xy(x, y), crs=2950)
    nn = gpd.sjoin_nearest(sp, pp, distance_col="d").drop_duplicates("row").sort_values("row")
    s["near_plot"], s["near_plot_dist"] = nn.plot_id.values, nn.d.values
    s["near_forest_type"] = nn.forest_type.values


# ---------------------------------------------------------------- MRNF disturbance polygons per tile --------
def wfs_tile(t):
    """Harvest / fire / other polygons intersecting the tile (EPSG:4326 bbox), cached as GeoJSON."""
    path = os.path.join(OUT, "mrnf_cache", t.tile_file_name.replace(".LAZ", ".json"))
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    inv = Transformer.from_crs(int(t.CODE_EPSG), 4326, always_xy=True)
    lo, la = inv.transform([t.hdr_xmin, t.hdr_xmax, t.hdr_xmin, t.hdr_xmax], [t.hdr_ymin, t.hdr_ymin, t.hdr_ymax, t.hdr_ymax])
    feats = []
    for layer in LAYERS:
        q = urllib.parse.urlencode({"service": "WFS", "version": "2.0.0", "request": "GetFeature",
                                    "typeNames": f"ms:{layer}", "outputFormat": "geojson",
                                    "bbox": f"{min(la)},{min(lo)},{max(la)},{max(lo)},urn:ogc:def:crs:EPSG::4326"})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(f"{WFS}?{q}", timeout=120) as r:
                    js = json.loads(r.read().decode("utf-8"))
                break
            except Exception as e:  # noqa: BLE001
                if attempt == 3:
                    raise
                time.sleep(5 * (attempt + 1))
        for f in js.get("features", []):
            f["properties"]["layer"] = layer
            feats.append(f)
    out = {"type": "FeatureCollection", "features": feats}
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(out, fh)
    return out


log("MRNF disturbance polygons per tile (cached after the first run)...")
polys = []
for i, t in enumerate(tiles.itertuples()):
    js = wfs_tile(t)
    for f in js["features"]:
        p = f["properties"]
        yr = p.get("an_perturb") or p.get("an_origine") or p.get("exercice")
        try:
            yr = int(float(yr))
        except (TypeError, ValueError):
            continue
        geom = shape(f["geometry"])
        if not geom.is_valid:
            geom = geom.buffer(0)
        kind = ("fire" if p["layer"] == "ca_feu_close_scale" else
                ("harvest (stand-replacing)" if p.get("origine") else "partial cut / tending")
                if p["layer"] == "ca_interv_for_close_scale" else "other natural")
        polys.append({"year": yr, "kind": kind, "code": p.get("origine") or p.get("perturb"), "geometry": geom})
    if (i + 1) % 50 == 0:
        log(f"  {i + 1}/{len(tiles)} tiles")
dist = gpd.GeoDataFrame(polys, crs=4326).to_crs(2950) if polys else gpd.GeoDataFrame(columns=["year", "kind", "geometry"], crs=2950)
dist = dist[dist.year >= tiles.als_date.str[:4].astype(int).min() - 1]   # only what can postdate the flights matters
dist.to_file(os.path.join(OUT, "mrnf_disturbance_after_als.gpkg"), driver="GPKG")
log(f"{len(dist)} MRNF polygons dated from the year before the first flight on")


def flag_post_als(s, kind):
    """Earliest MRNF event (year >= ALS year) intersecting each footprint."""
    if kind == "gedi":
        geo = gpd.GeoSeries(gpd.points_from_xy(s.x2950, s.y2950), crs=2950).buffer(GEDI_R)
    else:  # rectangle in EPSG:2950 (direction from the tile CRS; the rotation between MTM 8 and 9 is < 1 degree)
        ux, uy = s.ux.values, s.uy.values
        cx, cy = s.x2950.values, s.y2950.values
        geo = gpd.GeoSeries([Polygon([(x - SEG_HALF_L * a_ - SEG_HALF_W * b_, y - SEG_HALF_L * b_ + SEG_HALF_W * a_),
                                      (x + SEG_HALF_L * a_ - SEG_HALF_W * b_, y + SEG_HALF_L * b_ + SEG_HALF_W * a_),
                                      (x + SEG_HALF_L * a_ + SEG_HALF_W * b_, y + SEG_HALF_L * b_ - SEG_HALF_W * a_),
                                      (x - SEG_HALF_L * a_ + SEG_HALF_W * b_, y - SEG_HALF_L * b_ - SEG_HALF_W * a_)])
                             for x, y, a_, b_ in zip(cx, cy, ux, uy)], crs=2950)
    fp = gpd.GeoDataFrame({"row": np.arange(len(s))}, geometry=geo.values, crs=2950)
    als_year = s.tile_file_name.map(tiles.set_index("tile_file_name").als_date.str[:4].astype(int)).values
    j = gpd.sjoin(fp, dist[["year", "kind", "geometry"]], predicate="intersects")
    j = j[j.year.values >= als_year[j.row.values]]
    first = j.sort_values(["year", "kind"], kind="stable").groupby("row").first()   # same year: fire, then harvest, then the rest
    s["post_als_event"] = "none"
    s.loc[s.index[first.index], "post_als_event"] = first.kind.values
    s["post_als_year"] = np.nan
    s.loc[s.index[first.index], "post_als_year"] = first.year.values
    return s


gs = flag_post_als(gs.reset_index(drop=True), "gedi")
as_ = flag_post_als(as_.reset_index(drop=True), "atl08")
log("GEDI post-ALS:", gs.post_als_event.value_counts().to_dict())
log("ATL08 post-ALS:", as_.post_als_event.value_counts().to_dict())

# ---------------------------------------------------------------- write ------------------------------------
plots.drop(columns="geometry").to_csv(os.path.join(OUT, "plots_upe.csv"), index=False)
plots[["plot_id", "forest_type", "geometry"]].to_file(os.path.join(OUT, "plots_upe.gpkg"), driver="GPKG")
tiles.to_csv(os.path.join(OUT, "tiles_upe.csv"), index=False)
gs.to_csv(os.path.join(OUT, "samples_gedi.csv"), index=False)
as_.to_csv(os.path.join(OUT, "samples_atl08.csv"), index=False)
log("wrote", OUT)
