"""
04_make_plot_buffers.py - 150 m buffers around the PEP plots that have ALS metrics, used as the polygons of the
ICESat-2 / GEDI download (05_get_spaceborne_lidar.py, masked mode).

Author:    João Paulo Czarnecki de Liz (developer)
Co-author: Claude (Anthropic), AI coding assistant
Licence:   MIT (see LICENSE)

The comparison uses samples up to 100 m from the plot centre; the 50 m margin absorbs the 30 m pixels of the
server-side mask. Buffers are drawn in Québec Lambert (EPSG:32198, metres) and saved in lon/lat.

Input   data/plot_als_metrics.csv (provided) or data/derived/plot_als_metrics_full.csv + plot_tiles.csv (steps 1-3)
Output  data/derived/plot_buffers_150m.gpkg
Run     python -I scripts/04_make_plot_buffers.py
"""
import os
import geopandas as gpd
import pandas as pd

ROOT = os.environ.get("EXERCISE_ROOT", ".")
OUT = os.path.join(ROOT, "data", "derived"); os.makedirs(OUT, exist_ok=True)
full = os.path.join(OUT, "plot_als_metrics_full.csv")
if os.path.exists(full):          # your own extraction (steps 1-3)
    m = pd.read_csv(full)
    m = m[m.status == "ok"].merge(pd.read_csv(os.path.join(OUT, "plot_tiles.csv"))[["plot_id", "latitude", "longitude"]], on="plot_id")
else:                             # the table provided with the exercise
    m = pd.read_csv(os.path.join(ROOT, "data", "plot_als_metrics.csv"))
g = gpd.GeoDataFrame(m[["plot_id"]], geometry=gpd.points_from_xy(m.longitude, m.latitude), crs=4326)
g["geometry"] = g.to_crs(32198).buffer(150, quad_segs=8).to_crs(4326)
g.to_file(os.path.join(OUT, "plot_buffers_150m.gpkg"))
print(f"{len(g)} plot buffers -> {OUT}/plot_buffers_150m.gpkg")
