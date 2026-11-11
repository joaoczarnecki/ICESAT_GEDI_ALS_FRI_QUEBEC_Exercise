---
title: 9. Complete code
nav_order: 10
---

# 9. Complete code
{: .no_toc }

The whole exercise in one document: the complete code of every script, run step by step, with its output and the
checks of each step.
{: .fs-5 .fw-300 }

[Download exercise.Rmd](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/raw/main/exercise.Rmd){: .btn .btn-primary .mr-2 }
[Open the knitted exercise in a full page](exercise.html){: .btn .mr-2 }
[Browse the scripts on GitHub](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/tree/main/scripts){: .btn }

- **R chunks** run in the R session; **Python chunks** (marked `py`) run with the exercise's Python.
- With the default parameters, the heavy steps (1–3, 5, 6, 9, 10) use the tables provided in `data/` and the file
  knits in a few minutes. Set the parameters in the header to `true` to rebuild them.
- `exercise.Rmd` is generated from `exercise_template.Rmd` and `scripts/` by `tools/build_exercise_rmd.py`. To
  change the code, edit the script and rebuild.

<iframe src="exercise.html" title="Knitted exercise: complete code and results" style="width:100%; height:85vh; border:1px solid #ddd; border-radius:4px;" loading="lazy"></iframe>

| Step | Script | Language | Page |
|---|---|---|---|
| 0 | [`00_install_r_packages.R`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/blob/main/scripts/00_install_r_packages.R) | R | [1](01_setup_and_data.html) |
| 1 | [`01_match_plots_to_tiles.R`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/blob/main/scripts/01_match_plots_to_tiles.R) | R | [2](02_als_plot_metrics.html) |
| 2 | [`02_download_laz.R`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/blob/main/scripts/02_download_laz.R) | R | [2](02_als_plot_metrics.html) |
| 3 | [`03_extract_plot_als_metrics.R`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/blob/main/scripts/03_extract_plot_als_metrics.R) | R | [2](02_als_plot_metrics.html) |
| 4 | [`04_make_plot_buffers.py`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/blob/main/scripts/04_make_plot_buffers.py) | Python | [3](03_satellite_download.html) |
| 5 | [`05_get_spaceborne_lidar.py`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/blob/main/scripts/05_get_spaceborne_lidar.py) | Python | [3](03_satellite_download.html) |
| 6 | [`06_query_mrnf_events.py`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/blob/main/scripts/06_query_mrnf_events.py) | Python | [4](04_pairing.html) |
| 7 | [`07_build_plot_table.py`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/blob/main/scripts/07_build_plot_table.py) | Python | [4](04_pairing.html) |
| 8 | [`08_compare_figures.R`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/blob/main/scripts/08_compare_figures.R) | R | [5](05_agreement.html), [7](07_delay_and_season.html) |
| 9 | [`09_footprint_inputs.py`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/blob/main/scripts/09_footprint_inputs.py) | Python | [6](06_why_on_the_same_ground.html) |
| 10 | [`10_als_at_footprints.R`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/blob/main/scripts/10_als_at_footprints.R) | R | [6](06_why_on_the_same_ground.html) |
| 11 | [`11_footprint_figures.R`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/blob/main/scripts/11_footprint_figures.R) | R | [6](06_why_on_the_same_ground.html) |
| – | [`check_data.R`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/blob/main/scripts/check_data.R), [`summarise_lidar_by_polygon.R`](https://github.com/joaoczarnecki/ICESAT_GEDI_ALS_FRI_QUEBEC_Exercise/blob/main/scripts/summarise_lidar_by_polygon.R) | R | checks and helpers |
