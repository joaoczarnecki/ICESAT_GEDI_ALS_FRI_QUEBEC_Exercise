---
title: 1. Setup and data
nav_order: 2
---

# 1. Setup and data
{: .no_toc }

1. TOC
{:toc}

## Software

All scripts run from the repository root. They were tested on Windows 11 with Python 3.11 and R 4.6.2; nothing in them
is Windows-specific.

```bash
git clone https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise.git
cd ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise

# Python: SlideRule client + geospatial stack
python -m venv .venv
.venv/Scripts/python -m pip install -r requirements.txt      # on Linux/macOS: .venv/bin/python

# R: lidR (+ RCSF for the ground filter), sf, data.table, ggplot2 ...
Rscript scripts/00_install_r_packages.R
```

{: .note }
`lidR::csf()` needs the **RCSF** package, which is not installed with lidR. Without it every plot fails with
`ground_classify_error`. `00_install_r_packages.R` installs it.

Run Python scripts with `python -I` (isolated mode). It stops Python from importing a stray file in the working
folder that has the same name as a library.

## Data: what is provided, what you download

| Data | Where | Size | Needed for |
|---|---|---|---|
| **Plot ALS metrics** (10,560 plots) | provided: `data/plot_als_metrics.csv` | 1.3 MB | steps 3–6 |
| **MRNF disturbance records under the plots** | provided: `data/plot_mrnf_events.csv` | 1 MB | steps 4–6 |
| **PEP plots** (GeoPackage) | [Données Québec: Placettes-échantillons permanentes](https://www.donneesquebec.ca/recherche/dataset/placettes-echantillons-permanentes-1970-a-aujourd-hui) | ~100 MB zipped | steps 2 and 4 (forest type) |
| **Lidar tile index** (GeoPackage) | [Données Québec: Données lidar du Québec](https://www.donneesquebec.ca/recherche/dataset/donnees-lidar-du-quebec) → *Index des tuiles Lidar* (GPKG) | ~800 MB | step 2 only |
| **Lidar point clouds** (LAZ, 1 km tiles) | listed with their URL by script `01`; also on the [lidar download map](https://lidar-telechargement.portailcartographique.gouv.qc.ca/) and [Forêt ouverte](https://www.foretouverte.gouv.qc.ca/) | 7,708 tiles, 666 GB | step 2 only |
| **ICESat-2 ATL08, GEDI L2A** | streamed by script `05` from [SlideRule Earth](https://slideruleearth.io), no account needed | ~50 MB | step 3 |
| **MRNF forest interventions, fires, other disturbances** | queried by script `06` from the public MRNF web service | – | step 4 (optional) |

Put the two downloads under `data/raw/` with these names (the folder is ignored by git):

```
data/raw/PEP.gpkg            # unzip the PEP download and rename the .gpkg
data/raw/Index_Lidar.gpkg    # only for step 2
data/raw/laz/                # only for step 2: the LAZ tiles (script 02 fills it)
```

If the files are somewhere else, point the scripts at them instead of copying: `PEP_GPKG=/path/PEP.gpkg`,
`LIDAR_INDEX_GPKG=/path/Index_Lidar.gpkg`, `LAZ_DIR=/path/laz`.

{: .important }
The PEP licence (CC BY 4.0) asks for attribution to the MRNF, Direction des inventaires forestiers. For field work
on the plots or for sampling of any kind, contact inventaires.forestiers@mrnf.gouv.qc.ca first.

## What is in the provided tables

`data/plot_als_metrics.csv`: one row per plot whose ALS extraction succeeded (step 2):

| Column | Meaning |
|---|---|
| `plot_id` | PEP plot identifier (`id_pe` as a number) |
| `latitude`, `longitude` | plot centre (WGS84), from the PEP |
| `CODE_EPSG`, `NOM_TUILE` | MTM zone and name of the lidar tile used |
| `DATES_ACQUISITION` | date(s) the tile was flown |
| `CAPTEUR`, `DENSITE` | sensor and nominal point density of the lidar project |
| `pt_density_m2` | returns per m² actually found in the plot |
| `zq50`, `zq95`, `zmax` | 50th and 95th percentile and maximum height of **all** returns in the 400 m² plot (m) |

`data/plot_mrnf_events.csv`: the MRNF polygons (interventions, fires, other disturbances) that intersect each plot
circle, with the share of the circle they cover (`overlap`) and their year fields (`exercice`, `an_origine`,
`an_perturb`).

## Run it step by step: the R Markdown exercise

[`exercise.Rmd`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/raw/main/exercise.Rmd)
(download) runs the whole exercise in chunks, one per step. Each step shows what it produced and ends with a
check of its files. Open it in RStudio from the repository folder and run it chunk by chunk, or knit it.
[See the knitted result](exercise.html) for every output.

The heavy steps are off by default and use the provided tables instead. Switch them on in the header parameters:

| Parameter | Step | Default |
|---|---|---|
| `run_als` | 1–3: tiles, LAZ download (~700 GB), plot metrics | `false`: use `data/plot_als_metrics.csv` |
| `run_download` | 5: ICESat-2 and GEDI near the plots (2–3 h) | `false`: use `data/satellite/` |
| `run_events` | 6: MRNF disturbance records (~1 h) | `false`: use `data/plot_mrnf_events.csv` |
| `python` | path to the Python of the exercise | `.venv/Scripts/python.exe` or `.venv/bin/python` |

```r
rmarkdown::render("exercise.Rmd")                                        # defaults: a few minutes
rmarkdown::render("exercise.Rmd", params = list(run_download = TRUE))   # also redo the satellite download
```

## Checking the files at each step

`scripts/check_data.R` tests the inputs and outputs of each step:
- the layers and columns are those expected;
- there are no duplicated or empty rows;
- heights lie in 0–60 m, and dates and months are those requested;
- the GEDI server filters were applied, according to the `flags` bits;
- every `plot_id` exists in the ALS table.

Each check prints `PASS`, `WARN` (it runs, but read the reason) or `FAIL` (the next step would break or mislead).

```bash
Rscript scripts/check_data.R        # every step whose files are present
Rscript scripts/check_data.R 5      # one step
```

## Folder layout

```
scripts/      the numbered steps (00-08) and the R helper summarise_lidar_by_polygon.R
data/         provided tables; data/raw/ (your downloads) and data/derived/ (outputs) are git-ignored
docs/         this site; docs/assets/img/ receives the figures written by script 08
outputs/      tables and numbers written by script 08
```
