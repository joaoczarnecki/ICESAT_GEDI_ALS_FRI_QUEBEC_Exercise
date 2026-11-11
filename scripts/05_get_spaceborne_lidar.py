"""
05_get_spaceborne_lidar.py - ICESat-2 ATL08 segments or GEDI L2A / L4A footprints for ANY polygons
================================================================================================

Author:    João Paulo Czarnecki de Liz (developer)
Co-author: Claude (Anthropic), AI coding assistant
Licence:   MIT (see LICENSE)

Data come from the SlideRule Earth public API (slideruleearth.io). SlideRule finds the NASA
granules that cross your area, subsets them on its own servers and streams back only the samples
inside the query polygon: no Earthdata login, no token, no HDF5 download.

Products (--product)
  atl08    ICESat-2 ATL08 land & vegetation (release 007 as of 2026-11). One row = one 100 m
           along-track segment of one beam. Global, Oct 2018 -> present.
           Key fields: h_canopy (RH98 of canopy photons, m; NaN = no canopy found), h_mean_canopy,
           h_te_median (terrain), canopy_openness, segment_snowcover, spot (1/3/5 = strong beams),
           solar_elevation, rgt/cycle/gt (track identifiers). The 18 canopy-height percentiles
           (canopy_h_metrics) are expanded to columns ch_p10 ... ch_p95.
  gedi02a  GEDI L2A elevation and relative-height (RH) metrics. One row = one ~25 m footprint.
           51.6 S - 51.6 N only; Apr 2019 - Mar 2023, then again from Apr 2024.
           Key fields: rh25 ... rh100 (m above ground; rh98 ~ canopy top), elevation_lm (ground),
           elevation_hr (highest return), sensitivity, beam (5/6/8/11 = full-power), leaf_off_flag.
  gedi04a  GEDI L4A above-ground biomass density. Same footprints as L2A. Key field: agbd (Mg/ha).

What the script does
  1. Reads any vector file, reprojects to lon/lat (EPSG:4326) and repairs invalid geometry.
  2. Builds query regions: polygons closer than 2 x --group-buffer-m are merged into a group
     (one convex hull each). A group larger than --tile-km x --tile-km is cut into tiles, and
     each tile is queried with the convex hull of the polygon part inside it. This keeps every
     request small enough to finish in seconds and to be retried on its own.
     Masked mode (--mask-cell-km > 0), for many small scattered polygons such as buffers around
     field plots: polygons are grouped into square cells of that size; each cell is queried with
     the convex hull of its polygons PLUS a raster mask of the polygons themselves (SlideRule
     'region_mask'), so the server returns only the samples inside the polygons. In a test on 12
     plot buffers this returned 23 instead of 2,961 shots and ran ~10x faster.
  3. Requests one region x year (season = --months) at a time (--workers in parallel), retries 3x
     on server errors, and caches each answer in <out>_cache/: an interrupted run resumes.
  4. Applies the server-side quality filters for GEDI (degraded shots removed; L2A or L4A
     quality flag). ICESat-2 filters (snow, beams, height) are left to the summary step
     (summarise_lidar_by_polygon.R) so you can change them without downloading again.
  5. Merges the chunks, removes duplicates, and keeps samples that fall INSIDE each original
     polygon (a sample in nested or overlapping polygons is kept once per polygon).
  6. Writes <out>.parquet and <out>.csv (R reads the csv without the arrow package).

Usage (any Python >= 3.9 with: pip install sliderule geopandas pyarrow)
  python -I scripts/05_get_spaceborne_lidar.py catchments.gpkg --id-field site --product atl08 \
         --years 2019-2025 --months 6-9 --out out/atl08.parquet
  python -I scripts/05_get_spaceborne_lidar.py study_area.shp --id-field OBJECTID --product gedi02a \
         --years 2019-2025 --tile-km 40 --out out/gedi02a.parquet
  # all 101 RH values (for waveform-style plots; large files - use on small areas only)
  python -I scripts/05_get_spaceborne_lidar.py box.gpkg --id-field id --product gedi02a --rh all --out out/rh_all.parquet
  # 10,000 plot buffers across a province: masked mode, 4 requests at a time
  python -I scripts/05_get_spaceborne_lidar.py data/derived/plot_buffers_150m.gpkg --id-field plot_id --product gedi02a \
         --mask-cell-km 100 --workers 4 --out data/derived/gedi02a_plots.parquet

Tested 2026-11-10 with sliderule 5.8.1, geopandas 1.2, Python 3.11 (Windows).
"""
import argparse, sys, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import numpy as np, pandas as pd, geopandas as gpd, sliderule
from shapely.geometry import box
from sliderule import gedi

GEDI_MAX_LAT = 51.6                                 # GEDI orbit limit (ISS inclination); no data beyond
RH_STANDARD = [10, 25, 50, 75, 90, 95, 98, 100]     # GEDI RH percentiles kept by default (--rh standard)
ATL08_PCT = list(range(10, 100, 5))                 # the 18 percentiles in ATL08 canopy_h_metrics


def parse_range(s):
    """'2019-2025' -> (2019, 2025); '2021' -> (2021, 2021)."""
    a, b = (s.split("-") + [s])[:2]
    return int(a), int(b)


def query_regions(polys, buffer_m, tile_km):
    """Return a list of (name, lon/lat polygon) query regions covering all polygons.

    Neighbouring polygons share one region (fewer requests); a large region is tiled so that
    each request stays small. Each tile is queried with the convex hull of the polygon part
    inside it, so no time is spent on empty corners of the bounding box.
    """
    utm = polys.estimate_utm_crs()
    p = polys.to_crs(utm)
    merged = p.buffer(buffer_m).union_all()
    parts = list(merged.geoms) if merged.geom_type == "MultiPolygon" else [merged]
    regions, tile_m = [], tile_km * 1000
    for gi, part in enumerate(parts):
        x0, y0, x1, y1 = part.bounds
        if tile_km <= 0 or (x1 - x0 <= tile_m and y1 - y0 <= tile_m):
            regions.append((f"g{gi}", part.convex_hull))
            continue
        ti = 0
        for x in np.arange(x0, x1, tile_m):
            for y in np.arange(y0, y1, tile_m):
                piece = part.intersection(box(x, y, x + tile_m, y + tile_m))
                if piece.is_empty or piece.area < 1e4:        # skip slivers < 1 ha
                    continue
                regions.append((f"g{gi}_t{ti:03d}", piece.convex_hull)); ti += 1
    names = [r[0] for r in regions]
    geoms = gpd.GeoSeries([r[1] for r in regions], crs=utm).to_crs(4326)
    return [(n, g, None) for n, g in zip(names, geoms)]


def masked_regions(polys, cell_km, res_m):
    """Masked mode: one region per cell_km square cell = (name, convex hull, raster mask of the polygons)."""
    utm = polys.estimate_utm_crs()
    c = polys.to_crs(utm).geometry.centroid
    key = (np.floor(c.x / (cell_km * 1000)).astype(int).astype(str) + "_" +
           np.floor(c.y / (cell_km * 1000)).astype(int).astype(str))
    out = []
    for k, g in polys.groupby(key.values):
        gdf = gpd.GeoDataFrame(geometry=g.geometry.values, crs=4326)
        hull = gdf.union_all().convex_hull.buffer(res_m / 111_320)       # pad by one mask pixel
        mask = sliderule.toregion(gdf, cellsize=res_m / 111_320)["raster"]
        out.append((f"c{k}", hull, mask))
    return out


def fetch(product, poly, t0, t1, rh_mode, mask=None):
    """One SlideRule request. Returns a GeoDataFrame (index = time)."""
    parms = {"poly": poly, "t0": t0, "t1": t1}
    if mask is not None:
        parms["region_mask"] = mask                           # only samples inside the polygons come back
    if product == "atl08":
        return sliderule.run("atl08x", parms)                 # native ATL08 fields, all beams
    # GEDI: degraded shots out + the product's own quality flag. SlideRule silently IGNORES a
    # misspelled parameter, so check the 'flags' column (bit 0 degrade, 1 L2A ok, 2 L4A ok).
    parms |= {"degrade_filter": True}
    if product == "gedi02a":
        parms |= {"l2_quality_filter": True, "anc_fields": ["rh", "land_cover_data/leaf_off_flag"]}
        return gedi.gedi02ap(parms)
    parms |= {"l4_quality_filter": True, "anc_fields": ["land_cover_data/leaf_off_flag", "agbd_se"]}
    return gedi.gedi04ap(parms)


def expand_arrays(df, product, rh_mode):
    """Turn array columns into plain numeric columns so the output is portable (csv, R)."""
    if product == "atl08" and "canopy_h_metrics" in df:
        ok = df["canopy_h_metrics"].apply(lambda a: a is not None and np.size(a) == len(ATL08_PCT))
        m = np.full((len(df), len(ATL08_PCT)), np.nan, dtype="float32")
        if ok.any():
            m[ok.to_numpy()] = np.vstack(df.loc[ok, "canopy_h_metrics"].to_numpy())
        for j, k in enumerate(ATL08_PCT):
            df[f"ch_p{k}"] = m[:, j]
        df = df.drop(columns="canopy_h_metrics")
    if product == "gedi02a" and "rh" in df:
        rh = np.vstack(df["rh"].to_numpy()).astype("float32")          # 101 values: RH0 ... RH100
        keep = range(101) if rh_mode == "all" else RH_STANDARD
        for k in keep:
            df[f"rh{k}"] = rh[:, k]
        df = df.drop(columns="rh")
    return df.rename(columns={"land_cover_data/leaf_off_flag": "leaf_off_flag"})


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("polygons", help="any vector file GeoPandas can read (gpkg, shp, geojson ...)")
    ap.add_argument("--id-field", required=True, help="column that identifies each polygon")
    ap.add_argument("--product", choices=["atl08", "gedi02a", "gedi04a"], default="atl08")
    ap.add_argument("--years", default="2019-2025", help="e.g. 2019-2025 or 2021")
    ap.add_argument("--months", default="6-9", help="season window, e.g. 6-9 (leaf-on); 1-12 for all")
    ap.add_argument("--group-buffer-m", type=float, default=250,
                    help="polygons closer than 2x this are queried together (default 250 m)")
    ap.add_argument("--tile-km", type=float, default=40,
                    help="query regions larger than this (km) are tiled; 0 = never tile (default 40)")
    ap.add_argument("--rh", choices=["standard", "all"], default="standard",
                    help="GEDI L2A: keep RH10/25/50/75/90/95/98/100 (standard) or all 101 values")
    ap.add_argument("--mask-cell-km", type=float, default=0,
                    help="masked mode for many small scattered polygons: group them in cells of this size and "
                         "let the server return only samples inside the polygons (e.g. 100; default 0 = off)")
    ap.add_argument("--mask-res-m", type=float, default=30,
                    help="mask pixel size in m (masked mode); keep it well below the polygon size (default 30)")
    ap.add_argument("--workers", type=int, default=1, help="requests sent in parallel (default 1; 4 is polite)")
    ap.add_argument("--out", required=True, help="output .parquet (a .csv copy is written too)")
    a = ap.parse_args()

    # 1. polygons ------------------------------------------------------------------------
    polys = gpd.read_file(a.polygons)[[a.id_field, "geometry"]].to_crs(4326)
    polys["geometry"] = polys.make_valid()
    if a.product.startswith("gedi"):
        b = polys.geometry.bounds
        off = (b.miny > GEDI_MAX_LAT) | (b.maxy < -GEDI_MAX_LAT)
        if off.any():
            print(f"! {off.sum()} polygon(s) lie entirely beyond {GEDI_MAX_LAT} deg - GEDI has no data there; skipped:",
                  ", ".join(map(str, polys.loc[off, a.id_field])), flush=True)
            polys = polys[~off]
        if polys.empty:
            sys.exit("No polygon inside GEDI coverage - use --product atl08.")

    # 2. query regions -------------------------------------------------------------------
    y0, y1 = parse_range(a.years); m0, m1 = parse_range(a.months)
    out = Path(a.out); cache = out.with_name(out.stem + "_cache"); cache.mkdir(parents=True, exist_ok=True)
    if a.mask_cell_km > 0:
        regions = masked_regions(polys, a.mask_cell_km, a.mask_res_m)
    else:
        regions = query_regions(polys, a.group_buffer_m, a.tile_km)
    print(f"{len(polys)} polygon(s) -> {len(regions)} query region(s){' (masked)' if a.mask_cell_km > 0 else ''}; "
          f"{a.product}; {y0}-{y1}, months {m0}-{m1}", flush=True)
    gpd.GeoDataFrame({"region": [r[0] for r in regions]}, geometry=[r[1] for r in regions], crs=4326) \
       .to_file(cache / "query_regions.gpkg")                    # handy to map what was requested

    # 3-4. requests, one region x year at a time, cached ----------------------------------
    sliderule.init("slideruleearth.io", verbose=False)

    def one_chunk(task):
        name, geom, mask, y = task
        f = cache / f"{name}_{y}.parquet"
        if f.exists():
            return
        poly = sliderule.toregion(gpd.GeoDataFrame(geometry=[geom], crs=4326))["poly"]
        t0 = f"{y}-{m0:02d}-01T00:00:00Z"
        t1 = (pd.Timestamp(year=y, month=m1, day=1) + pd.offsets.MonthEnd(0)).strftime("%Y-%m-%dT23:59:59Z")
        df = None
        for attempt in range(3):
            try:
                t = time.time(); df = fetch(a.product, poly, t0, t1, a.rh, mask); break
            except Exception as e:                                           # busy server / timeout
                print(f"  {name} {y}: attempt {attempt + 1} failed ({e!r:.150})", flush=True); time.sleep(30)
        if df is None:
            print(f"  {name} {y}: giving up (rerun later; finished chunks are cached)", flush=True); return
        if len(df) == 0:
            df = gpd.GeoDataFrame({"empty": []}, geometry=[], crs=4326)
        else:
            df = expand_arrays(df.reset_index(), a.product, a.rh)           # time index -> column
        df.to_parquet(f)
        print(f"  {name} {y}: {len(df):7d} samples ({time.time() - t:.0f} s)", flush=True)

    tasks = [(n, g, m, y) for n, g, m in regions for y in range(y0, y1 + 1)]
    if a.workers > 1:
        with ThreadPoolExecutor(a.workers) as ex:
            list(ex.map(one_chunk, tasks))
    else:
        for task in tasks:
            one_chunk(task)

    # 5. merge, de-duplicate, clip to the original polygons --------------------------------
    parts = [gpd.read_parquet(f) for f in sorted(cache.glob("*_*.parquet"))]
    parts = [p.drop(columns=["empty"], errors="ignore") for p in parts if len(p)]
    if not parts:
        sys.exit("No samples returned for these polygons and dates.")
    seg = gpd.GeoDataFrame(pd.concat(parts, ignore_index=True), geometry="geometry")
    seg = seg.set_crs(4326, allow_override=True)       # SlideRule returns ITRF (EPSG:9989/7912); lon/lat = WGS84 to cm
    seg = seg.drop(columns=["index", "level_0"], errors="ignore")
    keys = ["time_ns", "rgt", "cycle", "gt", "segment_id_beg"] if a.product == "atl08" else ["time", "beam"]
    seg = seg.drop_duplicates(subset=[k for k in keys if k in seg])
    joined = gpd.sjoin(seg, polys, predicate="within", how="inner").drop(columns="index_right")
    joined["lon"] = joined.geometry.x; joined["lat"] = joined.geometry.y
    joined = pd.DataFrame(joined.drop(columns="geometry"))

    # 6. write -----------------------------------------------------------------------------
    joined.to_parquet(out); joined.to_csv(out.with_suffix(".csv"), index=False)
    tcol = "time_ns" if a.product == "atl08" else "time"
    yrs = pd.to_datetime(joined[tcol]).dt.year.value_counts().sort_index()
    print(f"\n{len(seg)} unique samples in the query regions; {len(joined)} sample x polygon rows -> {out}")
    print("samples per year:", yrs.to_dict())
    n = joined.groupby(a.id_field).size()
    if len(n) <= 50:
        print(n.rename("n").to_string())
    else:
        print(f"{len(n)} of {len(polys)} polygons have samples; per polygon: median {n.median():.0f}, max {n.max()}")


if __name__ == "__main__":
    main()
