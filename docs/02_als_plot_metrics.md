---
title: 2. ALS metrics of each plot
nav_order: 3
---

# 2. ALS metrics of each plot
{: .no_toc }

This step builds `data/plot_als_metrics.csv` from the public lidar tiles. It takes days because the tiles weigh
about 700 GB. **The table is provided, so you can skip to [step 3](03_satellite_download.html).** Run this step to
check the method, to add metrics, or to use plots and tiles of your own.
{: .fs-5 .fw-300 }

1. TOC
{:toc}

## 2.1 Match each plot to a lidar tile (`01_match_plots_to_tiles.R`)

The provincial tile index has one polygon per 1 km tile and acquisition. The script:

1. reads the 12,834 PEP plot centres (layer `placette`);
2. keeps the most recent acquisition of each tile (`PLUS_RECENTE = "Oui"`);
3. joins plots to tile polygons, and keeps the classified point cloud (`Données classifiées`) when a plot falls in
   several records;
4. writes the tile name, MTM zone (`CODE_EPSG`), acquisition dates and download URL of each plot.

```bash
Rscript scripts/01_match_plots_to_tiles.R          # ~5 min; data/derived/plot_tiles.csv
```

Result on the November 2026 index: 11,395 plots have a tile, 11,357 of them classified, covering 8,080 tiles. The
acquisitions span 2009–2025, with 70% of them in 2017–2024.

## 2.2 Download the tiles (`02_download_laz.R`)

```bash
TILE_LIMIT=20 WORKERS=4 Rscript scripts/02_download_laz.R   # try a few first
WORKERS=6 Rscript scripts/02_download_laz.R                  # all classified tiles; reruns skip finished files
```

A tile is 20–150 MB (median 59 MB); the 7,708 tiles behind the provided table total 666 GB. Each download retries
up to six times with a growing wait, and an interrupted file is deleted so it gets downloaded again on the next run.

## 2.3 Extract the plot metrics (`03_extract_plot_als_metrics.R`)

The tiles' own ground classification varies between lidar projects across the province, so the script redoes it
for every plot. For each plot:

| Step | lidR call | Setting |
|---|---|---|
| Read a window around the plot centre (in the tile's MTM zone) | `readLAS(filter = "-inside ...")` | 60 m × 60 m |
| Remove noise | `classify_noise(ivf())` | defaults |
| Reclassify the ground | `classify_ground(csf())` | `class_threshold = 0.05` |
| Normalise heights | `normalize_height(tin())` | |
| Keep the plot | `clip_circle()` | radius 11.28 m (400 m²) |
| Drop implausible heights | `filter_poi()` | keep −2 to 60 m; heights floored at 0 |
| Flag a failed normalisation | | > 10% of returns outside −2 to 60 m |
| Metrics | `stdmetrics_z/_i/_rn`, `VCI`, `entropy`, ... | about 80 per plot |

```bash
PLOT_LIMIT=50 WORKERS=6 Rscript scripts/03_extract_plot_als_metrics.R    # test
WORKERS=6 Rscript scripts/03_extract_plot_als_metrics.R                  # all; ~3 h; checkpointed
```

The `status` column of the output records why a plot failed. Of the 10,788 plots of the original run:
- 10,560 are `ok`;
- 198 are `insufficient_ground_points` (fewer than 10 ground returns in the window);
- 28 are `excessive_height_outliers`;
- 2 are empty.

{: .highlight }
**Check.** Twelve random plots were extracted again with this script. Every metric matched the provided table to
within 4 × 10⁻¹¹ (floating-point noise). `zq95` and `zmax` were identical.

### The metrics this exercise uses

| Plot metric | Definition | Satellite counterpart |
|---|---|---|
| `zq95` | 95th percentile of the heights of **all** returns in the plot | GEDI **RH95**: same definition, on the waveform energy |
| `zq95` | | ATL08 **`h_canopy`**: 98th percentile of the *canopy* photons over a 100 m segment. Close, not identical |
| `zq50` | median height of all returns | GEDI **RH50** |
| `zmax` | highest return | GEDI RH100 (sensitive to single tall trees) |

GEDI RH metrics are percentiles of the returned energy counted from the ground up, so the ground is in the
distribution. The ALS percentiles of all returns, ground included, are their counterpart. ATL08 canopy metrics
leave out the ground photons. Their exact ALS counterpart (percentiles of the returns more than about 0.5 m above
the ground, over the 100 m segment) is not in a plot table, so `zq95` is used as the nearest match.
