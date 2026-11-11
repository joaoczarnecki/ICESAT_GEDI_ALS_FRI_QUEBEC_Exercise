---
title: 4. Pairing plots and samples
nav_order: 5
---

# 4. Pairing plots and satellite samples
{: .no_toc }

Give each plot a forest type and its disturbance history, then turn the samples into plot–sample pairs with a
distance, a delay and a disturbance flag.
{: .fs-5 .fw-300 }

1. TOC
{:toc}

## 4.1 Disturbance records (`06_query_mrnf_events.py`, optional)

The forest changes between the ALS flight and the satellite date. A harvest in between turns a fair comparison into
a meaningless one. The MRNF publishes three layers as a web feature service (WFS):

| Layer | Content |
|---|---|
| `ca_interv_for_close_scale` | harvests (`origine`: clearcut, cut with protection of regeneration, ...) and partial cuts and tending (`perturb`) |
| `ca_feu_close_scale` | fires |
| `ca_perturb_autre_close_scale` | windthrow, insect outbreaks, dieback, ice storm, ... |

The script queries the polygons that intersect each 11.28 m plot circle and records the share of the circle each one
covers. Results are cached per plot.

```bash
python -I scripts/06_query_mrnf_events.py      # ~1 h; data/derived/plot_mrnf_events.csv (same content as data/plot_mrnf_events.csv)
```

## 4.2 Plot table (`07_build_plot_table.py`)

```bash
python -I scripts/07_build_plot_table.py       # needs data/raw/PEP.gpkg; data/derived/plots_province.csv
```

The script adds four things to the ALS metrics:

- **ALS date and month:** the first flight date of the tile.
- **Bioclimatic domain:** from the PEP table `classi_eco_pe`.
- **Forest type:** from the live trees (diameter ≥ 9.1 cm) of the PEP measurement closest to the ALS date. The rules use live basal area (BA):

  | Forest type | Rule | Plots |
  |---|---|---|
  | Softwood | softwood ≥ 75% of BA | 4,106 |
  | Hardwood | hardwood ≥ 75% of BA | 2,266 |
  | Mixed | otherwise | 2,535 |
  | Open / regenerating | live BA < 4 m²/ha | 1,652 |

  The softwoods are fir, spruces, pines, cedar, hemlock and larches.
- **Disturbance events since 2010:** those covering ≥ 50% of the plot, with their year. The year is the disturbance year when one is given, else the stand-origin year, else the record year. 1,476 plots have at least one.

## 4.3 Pairs (inside `08_compare_figures.R`)

A **pair** is one satellite sample and one plot within 100 m of each other. A sample near two plots makes two pairs.
The script:

1. applies the default quality filters (page 3) and keeps June–September samples;
2. computes the distance from the plot centre in Québec Lambert (EPSG:32198);
3. computes the **delay** = satellite date − ALS date, in years. It is negative when the satellite came first: the
   ALS of half the plots was flown in 2019–2025, the same years as the satellites;
4. flags the pair as **disturbed** when an MRNF event year lies between the ALS year and the satellite year, both
   included;
5. sets the compared values: GEDI `rh95` against plot `zq95`, GEDI `rh50` against `zq50`, and ATL08 `h_canopy` against `zq95`.

Two distances define a sample that is "on the plot":

| Sensor | Distance | Why |
|---|---|---|
| GEDI | ≤ 25 m | footprint radius 12.5 m + plot radius 11.28 m: the footprint and the plot overlap |
| ICESat-2 | ≤ 50 m | the segment is 100 m long and only ~14 m wide. A centre up to 50 m away *along* the track still covers the plot, but across the track the plot is missed beyond ~18 m. So these pairs mix overlapping and adjacent ground |

**Uncertainty.** The pairs of one plot share the same ALS and the same ground, so they are not independent.
Every 95% interval in the figures is a bootstrap over **plots**, not over pairs.

```bash
Rscript scripts/08_compare_figures.R           # ~3 min; figures to docs/assets/img/, tables to outputs/
```
