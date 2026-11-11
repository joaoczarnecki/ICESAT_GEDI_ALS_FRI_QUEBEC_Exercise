# ICESat-2 and GEDI against airborne lidar at Québec's permanent forest plots

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.24139153.svg)](https://doi.org/10.5281/zenodo.24139153)

A reproducible exercise. How close are ICESat-2 ATL08 and GEDI L2A canopy heights to airborne lidar (ALS) at
about 10,000 permanent sample plots (PEP) of Québec, and how much uncertainty does the delay between the ALS
flight and the satellite add?

**Tutorial (step by step, with results):** https://joaoczarnecki.github.io/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/

## Quick start (about 3 hours, mostly downloading)

```bash
python -m venv .venv && .venv/Scripts/python -m pip install -r requirements.txt   # .venv/bin/python on Linux/macOS
Rscript scripts/00_install_r_packages.R
# put the PEP GeoPackage in data/raw/PEP.gpkg (Données Québec, see docs/01_setup_and_data.md)
.venv/Scripts/python -I scripts/04_make_plot_buffers.py
for p in gedi02a atl08; do
  .venv/Scripts/python -I scripts/05_get_spaceborne_lidar.py data/derived/plot_buffers_150m.gpkg --id-field plot_id \
      --product $p --years 2019-2025 --months 6-9 --mask-cell-km 100 --workers 4 --out data/derived/${p}_plots.parquet
done
.venv/Scripts/python -I scripts/07_build_plot_table.py
Rscript scripts/08_compare_figures.R
```

Steps 1–3 (matching plots to lidar tiles, downloading ~700 GB of LAZ, extracting the plot metrics) and step 6
(disturbance records) are optional. Their results are provided in `data/`.

Or run everything step by step in R Markdown, with a check of the files after each step:
`rmarkdown::render("exercise.Rmd")`. The `.Rmd` contains the complete code of every script as chunks. Check the files alone with `Rscript scripts/check_data.R`.

## Contents

| Path | What |
|---|---|
| `scripts/00`–`08` | The steps, in order. Each script starts with what it reads, writes and how long it takes |
| `scripts/09`–`11` | Page 6: ALS cut to each satellite footprint in one region (UPE 14–15) |
| `scripts/summarise_lidar_by_polygon.R` | Helpers: read the satellite tables, quality filters, per-polygon summaries |
| `scripts/check_data.R` | PASS / WARN / FAIL checks of the inputs and outputs of each step |
| `exercise.Rmd` | The whole exercise as R Markdown chunks (heavy steps off by default) |
| `data/plot_als_metrics.csv` | ALS metrics of 10,560 PEP plots (P50, P95 and maximum height of all returns, point density, tile, date) |
| `data/plot_mrnf_events.csv` | MRNF harvest, fire and disturbance polygons under each plot |
| `data/satellite/` | The ICESat-2 and GEDI samples within 150 m of the plots (output of step 5) |
| `data/study_area/` | The UPE 14–15 region of page 6 |
| `data/why/` | Outputs of steps 9–10 (samples in the region's ALS tiles and their ALS counterparts), so step 11 runs without the LAZ |
| `tools/build_exercise_rmd.py` | Rebuilds `exercise.Rmd` from `exercise_template.Rmd` and the scripts |
| `docs/` | The GitHub Pages site |

## How to cite

Czarnecki de Liz, J. P. (2026). *ICESat-2 and GEDI against airborne lidar at Québec's permanent forest plots: a
reproducible exercise* (v1.0.0). Zenodo. https://doi.org/10.5281/zenodo.24139153

This DOI always resolves to the latest version; each version also has its own DOI on the
[Zenodo record](https://doi.org/10.5281/zenodo.24139153). GitHub's *Cite this repository* button gives the same
citation in APA and BibTeX.

## Credits and licences

Exercise and code: **João Paulo Czarnecki de Liz** (Université Laval), developed with **Claude** (Anthropic) as a
coding assistant. Code: MIT (`LICENSE`). Text, figures and data products: CC BY 4.0 (`LICENSE-docs.md`).

Data:

- **PEP plots, airborne lidar and forest disturbance maps:** Ministère des Ressources naturelles et des Forêts du Québec, CC BY 4.0.
- **ICESat-2 ATL08 and GEDI L2A:** NASA, through SlideRule Earth.
