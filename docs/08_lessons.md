---
title: 8. Lessons and limits
nav_order: 9
---

# 8. Lessons and limits
{: .no_toc }

1. TOC
{:toc}

## Lessons

1. **Few plots have a satellite sample on them.** Over seven summers, a GEDI footprint overlaps 8% of the plots and
   an ICESat-2 segment crosses 4% of them. With 10,000 plots that is still hundreds, enough for a real comparison;
   with 100 plots it would be a handful. Download only near the plots (masked mode, page 3), not whole regions.
2. **GEDI RH95 is an unbiased stand-in for the plot ALS P95.** Footprint on the plot, delay ≤ 2 years: mean
   difference −0.3 m, RMSE 4.1 m, and 2.9 m in softwood stands with leaf-on ALS. Most of the RMSE comes from a
   tail of large differences (15% beyond ±5 m), not from a general offset.
3. **ICESat-2 `h_canopy` is not a plot P95.** It reads about 3 m higher (P98 of canopy photons over 100 m against
   P95 of all returns in 400 m²), RMSE 5.9 m. Use it for heights over strips and areas, or calibrate it first.
   On its own ground, against the matching ALS definition, it is unbiased (+0.1 m, page 6).
4. **Most of the error against a plot is different ground, not the satellite.** With ALS cut to the same GEDI
   footprints within 100 m of a plot, the RMSE against the plot P95 is still 4.0 m; the satellite brings it to
   5.2 m (page 6).
5. **Distance costs little up to 50 m, then GEDI degrades.** The GEDI RMSE grows from 4.0 to 5.0 m between 25 and
   100 m from the plot. Neighbourhood samples are usable for areas, not as plot values.
6. **The delay costs ICESat-2 about 1 m of RMSE every 5 years; GEDI shows no measurable effect within 10 years.**
   The cost appears only when the same plots are compared at different delays. Across plots, the delay is
   confounded with the region and the lidar project.
7. **A recorded disturbance in between costs more than the delay.** It adds about 2 m of RMSE. Filter the pairs
   with the MRNF maps (page 4); an exact match of years is not needed.
8. **Prefer leaf-on ALS for anything below the canopy top.** Against a leaf-off ALS, GEDI RH50 in hardwood plots
   reads 6.7 m higher than the ALS P50; against a leaf-on ALS it reads 1.7 m lower. Top heights are much less affected.
9. **Check every step.** `scripts/check_data.R` caught slivers in the disturbance records and a plot with no field
   measurement. It also confirms that the GEDI server filters were applied, through the `flags` bits, which
   SlideRule would not report if a parameter were misspelled.

## Limits of this exercise

- **Geolocation.** The GEDI footprint position is known to about 10 m and the ICESat-2 segment position to a few
  metres. PEP plot centres come from field GPS readings. Part of the spread at "≤ 25 m" is geolocation, not height
  error.
- **ATL08 vs a plot.** `h_canopy` describes a 100 m × 14 m strip and the plot is a 400 m² circle. Even on the plot,
  the two do not see the same ground.
- **Disturbance records.** The MRNF maps cover recorded interventions, fires and mapped natural disturbances. Small
  natural changes are not in them (single-tree mortality, light budworm defoliation, gaps). They stay in the
  "undisturbed" pairs and inflate their spread.
- **ALS heterogeneity.** The lidar projects differ in sensor, density (1.5 to 10+ pts/m²) and season. Here the
  plots' ALS is the reference, but it has its own errors.
- **GEDI coverage.** GEDI stops at 51.6°N (100 plots without GEDI) and has no data from March 2023 to April 2024.

## References

- Dubayah, R., Hofton, M., Blair, J., Armston, J., Tang, H., Luthcke, S. (2021). *GEDI L2A Elevation and Height Metrics
  Data Global Footprint Level V002*. NASA EOSDIS Land Processes DAAC. https://doi.org/10.5067/GEDI/GEDI02_A.002
- Neuenschwander, A., Pitts, K., Jelley, B., Robbins, J., Markel, J., Popescu, S., Nelson, R., Harding, D., Pederson, D.,
  Klotz, B., Sheridan, R. (2025). *ATLAS/ICESat-2 L3A Land and Vegetation Height* (ATL08), Version 7. NASA National Snow
  and Ice Data Center DAAC, Boulder, Colorado. https://doi.org/10.5067/ATLAS/ATL08.007
- Shean, D., Swinski, J. P., Smith, B., Sutterley, T., Henderson, S., Ugarte, C., Lidwa, E., Neumann, T. (2023).
  SlideRule: Enabling rapid, scalable, open science for the NASA ICESat-2 mission and beyond. *Journal of Open Source
  Software*, 8(81), 4982. https://doi.org/10.21105/joss.04982
- Roussel, J.-R., Auty, D., Coops, N. C., Tompalski, P., Goodbody, T. R. H., Sánchez Meador, A., Bourdon, J.-F.,
  de Boissieu, F., Achim, A. (2020). lidR: An R package for analysis of Airborne Laser Scanning (ALS) data. *Remote
  Sensing of Environment*, 251, 112061. https://doi.org/10.1016/j.rse.2020.112061
- Zhang, W., Qi, J., Wan, P., Wang, H., Xie, D., Wang, X., Yan, G. (2016). An easy-to-use airborne LiDAR data filtering
  method based on cloth simulation. *Remote Sensing*, 8(6), 501. https://doi.org/10.3390/rs8060501
- Ministère des Ressources naturelles et des Forêts du Québec. *Placettes-échantillons permanentes 1970 à aujourd'hui*;
  *Données lidar du Québec*; *Interventions forestières, feux et perturbations naturelles*. Données Québec, CC BY 4.0.
