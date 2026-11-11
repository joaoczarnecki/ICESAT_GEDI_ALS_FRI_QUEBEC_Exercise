---
title: 3. ICESat-2 and GEDI near the plots
nav_order: 4
---

# 3. ICESat-2 and GEDI near the plots
{: .no_toc }

Download only the satellite samples that fall within 150 m of a plot, for 10,560 plots spread over Québec, in a
few hours and without an Earthdata account.
{: .fs-5 .fw-300 }

1. TOC
{:toc}

## 3.1 Products

| | ICESat-2 ATL08 (release 007) | GEDI L2A (version 2) |
|---|---|---|
| Sample | 100 m segment along one beam; ~14 m wide | 25 m footprint, every ~60 m along track |
| Canopy height | `h_canopy` = 98th percentile of the canopy photons (m above ground) | `rh95`, `rh98`: height below which 95% / 98% of the waveform energy returned (m above the ground return) |
| Coverage here | all plots (global coverage) | plots south of 51.6°N: 10,460 of 10,560 |
| Period used | June–September 2019–2025 | June–September 2019–2025; no data March 2023 – April 2024 (instrument stored on the ISS); 2025 partial at download time |

Both come through [SlideRule Earth](https://slideruleearth.io). SlideRule finds the NASA files (granules) that cross
an area, subsets them on its own servers and streams back only the samples inside a polygon. No account, token or
HDF5 download is needed.

## 3.2 Plot buffers (`04_make_plot_buffers.py`)

```bash
python -I scripts/04_make_plot_buffers.py       # data/derived/plot_buffers_150m.gpkg, 10,560 circles of 150 m
```

The comparison uses samples up to 100 m from the plot centre. The extra 50 m absorbs the 30 m pixels of the
server-side mask (next section).

## 3.3 Masked download (`05_get_spaceborne_lidar.py --mask-cell-km`)

Sending 10,560 tiny polygons one by one would mean 10,560 × 7 years × 2 products requests. Sending the convex hull
of all of them would download the whole province. **Masked mode** does neither:

1. the buffers are grouped into 100 km × 100 km cells (84 cells here);
2. each request covers one cell and one summer;
3. each request sends the convex hull of the cell's buffers as the search area, plus a raster *mask* of the buffers
   (SlideRule's `region_mask` parameter);
4. the server drops every sample outside the mask before sending anything back.

```bash
PY=.venv/Scripts/python      # or .venv/bin/python
for p in gedi02a atl08; do
  $PY -I scripts/05_get_spaceborne_lidar.py data/derived/plot_buffers_150m.gpkg --id-field plot_id \
      --product $p --years 2019-2025 --months 6-9 --mask-cell-km 100 --workers 4 \
      --out data/derived/${p}_plots.parquet
done            # each writes .parquet + .csv; the two products can run at the same time
```

{: .highlight }
**Why the mask matters.** On a test with 12 plots inside a 20 km box over two summers, the request without the
mask returned 2,961 GEDI shots in 102 s. With the mask it returned 23 shots in 11 s, and the 13 shots within
100 m of a plot were the same in both.

For the province, with 4 requests at a time per product and both products running together, the run took about
1 h 45 min. Each product has 588 chunks of one cell × one summer, and a chunk takes 7 to 60 s depending on the
server load. Each answer is cached in `data/derived/<product>_plots_cache/`, so an interrupted run resumes where it
stopped.

What came back, before the quality filters:
- **GEDI:** 54,091 shots near 7,620 of the 10,460 plots south of 51.6°N.
- **ICESat-2:** 14,282 ATL08 segments near 3,407 of the 10,560 plots.

Both tables are provided in `data/satellite/`; use them to skip this step. One ICESat-2 chunk (one 100 km cell,
summer 2024) failed three times on the server side and is missing: 1 of 588.

## 3.4 Quality filters

Some filters are applied by the server, others later, in R. The R filters can be changed without downloading again.

| Filter | Where | Rule |
|---|---|---|
| GEDI degraded shots | server | `degrade_filter = True` |
| GEDI L2A quality flag | server | `l2_quality_filter = True` |
| GEDI leaf-off flag | R (`lidar_filter`) | keep `leaf_off_flag == 0` |
| GEDI beam sensitivity | R | keep `sensitivity >= 0.95` |
| ATL08 beam | R | strong beams only (spots 1, 3, 5) |
| ATL08 snow | R | `segment_snowcover == 1` (snow-free) |
| Implausible heights | R | top height ≤ 60 m |
| Season | R (step 5) | satellite date in June–September |

{: .warning }
**Pitfalls met here.**
- **Misspelled parameters:** SlideRule silently ignores a parameter it does not know. Check the `flags` column of GEDI (bit 0 = degraded, bit 1 = L2A quality) to see whether a filter was applied.
- **Dates outside the window:** SlideRule selects whole granules by date, so a few samples can fall just outside `t0`–`t1`. Filter on the sample's own time.
- **Granule read failures:** the server sometimes logs `H5Coro::Future read failure` for a beam of a GEDI granule. That beam is then missing from that chunk; rerunning the chunk (delete its cached file) usually recovers it.
- **Coordinate systems:** results come back in ITRF (EPSG:9989 or 7912). At this scale the lon/lat equal WGS84 to the centimetre, so set the CRS to EPSG:4326 before a spatial join.
