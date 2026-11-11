###############################################################################
# summarise_lidar_by_polygon.R - per-polygon canopy metrics from 05_get_spaceborne_lidar.py output
#
# Author:    João Paulo Czarnecki de Liz (developer)
# Co-author: Claude (Anthropic), AI coding assistant
# Licence:   MIT (see LICENSE)
#
#   source("scripts/summarise_lidar_by_polygon.R")
#   d <- read_lidar("out/atl08.csv")                      # csv (base R) or parquet (needs arrow)
#   s <- lidar_summary(d, product = "atl08", id = "site",
#                      periods = list(pre = 2019:2022, post = 2024:2025))
#   ch <- lidar_change(s, id = "site")                    # post - pre per polygon
#
#   # ANY other set of polygons, e.g. a 5 km hexagon grid over a study area (needs sf):
#   hex <- lidar_hexgrid(sf::st_read("study_area.shp"), cell_km = 5)
#   d   <- lidar_assign(d, hex, id = "cell")              # adds the 'cell' column (point-in-polygon)
#   s   <- lidar_summary(d, product = "atl08", id = "cell")
#
# Functions
#   read_lidar()      read the csv / parquet written by 05_get_spaceborne_lidar.py
#   lidar_filter()    product-specific quality filters (called by lidar_summary; usable alone)
#   lidar_summary()   metrics per polygon x period, with pass-level bootstrap 95% CIs
#   lidar_change()    wide table + differences between two periods
#   lidar_assign()    attach samples to any polygon layer (sf), e.g. stands, plots, grid cells
#   lidar_hexgrid()   hexagon grid clipped to an area, ready for lidar_assign()
#
# Metrics per polygon x period
#   n          samples kept after filtering (ATL08 100 m segments / GEDI ~25 m shots)
#   n_passes   independent passes (ATL08: rgt + beam + date; GEDI: orbit + beam) - the REAL
#              sample size: samples along one pass are spatially autocorrelated
#   cover      share of samples with canopy height >= cover_thr (default 2 m)        [atl08, gedi02a]
#   cover_tall share of samples >= tall_thr (default 5 m; no CI). GEDI rarely reports RH98 < 2-3 m,
#              so GEDI cover at 2 m saturates near 100%: use cover_tall to compare the sensors
#   h_med      median canopy height of canopy samples (ATL08 h_canopy = RH98; GEDI rh98)
#   h_p90      90th percentile of canopy height (a 'dominant height' style metric)
#   agbd_mean  mean above-ground biomass density, Mg/ha                              [gedi04a]
#   *_lo/_hi   95% CI from a bootstrap that resamples whole passes (resampling single samples
#              would treat 100 segments of one pass as 100 independent draws -> CIs far too narrow)
#   flag_low_n TRUE when n < min_n or n_passes < min_passes - treat as indicative only
#
# Filters (defaults follow the ATL08 / GEDI user guides; adjust for your biome)
#   atl08   snow-free (segment_snowcover == 1); strong beams (spot 1, 3, 5) unless beams = "all";
#           night passes only if night_only = TRUE (solar_elevation < 0: no sunlight noise);
#           h_canopy NA -> 0 m (ATL08 found no canopy photons = open ground); h_canopy <= max_h
#   gedi02a leaf-on (leaf_off_flag == 0); sensitivity >= min_sens; optional full-power beams only
#           (beam 5, 6, 8, 11); rh98 <= max_h. Degrade + L2A quality filters ran at download.
#   gedi04a leaf-on; sensitivity >= min_sens; degrade + L4A quality filters ran at download.
###############################################################################

read_lidar <- function(file) {
  if (grepl("\\.parquet$", file)) {
    if (!requireNamespace("arrow", quietly = TRUE)) file <- sub("\\.parquet$", ".csv", file)
    else return(as.data.frame(arrow::read_parquet(file)))
  }
  read.csv(file)
}

detect_product <- function(d) {
  if ("h_canopy" %in% names(d)) "atl08" else if ("agbd" %in% names(d)) "gedi04a" else "gedi02a"
}

lidar_filter <- function(d, product = detect_product(d), max_h = 60, min_sens = 0.95,
                         beams = c("strong", "all"), night_only = FALSE, power_beams_only = FALSE) {
  beams <- match.arg(beams)
  if (product == "atl08") {
    d <- d[d$segment_snowcover == 1, ]
    if (beams == "strong") d <- d[d$spot %in% c(1, 3, 5), ]
    if (night_only) d <- d[d$solar_elevation < 0, ]
    d$h <- ifelse(is.na(d$h_canopy), 0, d$h_canopy)          # no canopy photons -> 0 m
    d <- d[d$h <= max_h, ]
    d$time <- d$time_ns
    d$pass <- paste(d$rgt, d$gt, substr(d$time, 1, 10))      # one beam on one date
  } else {
    if ("leaf_off_flag" %in% names(d)) d <- d[d$leaf_off_flag == 0, ]
    d <- d[d$sensitivity >= min_sens, ]
    if (power_beams_only) d <- d[d$beam %in% c(5, 6, 8, 11), ]
    if (product == "gedi02a") { d$h <- pmax(d$rh98, 0); d <- d[d$h <= max_h, ] }
    d$pass <- paste(d$orbit, d$beam)                          # one beam on one orbit
  }
  d$year <- as.integer(substr(d$time, 1, 4))
  d
}

boot_pass <- function(x, pass, fun, B = 500) {
  if (length(unique(pass)) < 3) return(c(NA, NA))            # too few passes for a CI
  idx <- split(seq_along(x), pass)
  v <- replicate(B, { s <- unlist(idx[sample(length(idx), replace = TRUE)], use.names = FALSE); fun(x[s]) })
  unname(quantile(v, c(0.025, 0.975), na.rm = TRUE))
}

lidar_summary <- function(x, product = NULL, id, periods = list(all = 2018:2035), cover_thr = 2, tall_thr = 5,
                          min_n = 50, min_passes = 3, B = 500, seed = 1, filter = TRUE, ...) {
  d <- if (is.character(x)) read_lidar(x) else x
  if (is.null(product)) product <- detect_product(d)
  product <- match.arg(product, c("atl08", "gedi02a", "gedi04a"))
  set.seed(seed)
  if (filter) d <- lidar_filter(d, product, ...)
  d <- d[!is.na(d[[id]]), ]
  d$period <- NA_character_
  for (p in names(periods)) d$period[d$year %in% periods[[p]]] <- p
  d <- d[!is.na(d$period), ]
  cov_fun <- function(h) mean(h >= cover_thr)
  med_fun <- function(h) median(h[h >= cover_thr])
  p90_fun <- function(h) unname(quantile(h[h >= cover_thr], 0.9))
  out <- lapply(split(d, list(d[[id]], d$period), drop = TRUE), function(g) {
    r <- data.frame(id = g[[id]][1], period = g$period[1], n = nrow(g), n_passes = length(unique(g$pass)))
    if (product == "gedi04a") {
      ci <- boot_pass(g$agbd, g$pass, mean, B)
      r <- cbind(r, agbd_mean = mean(g$agbd), agbd_lo = ci[1], agbd_hi = ci[2])
    } else {
      ci_c <- boot_pass(g$h, g$pass, cov_fun, B); ci_h <- boot_pass(g$h, g$pass, med_fun, B)
      r <- cbind(r, cover = cov_fun(g$h), cover_lo = ci_c[1], cover_hi = ci_c[2], cover_tall = mean(g$h >= tall_thr),
                 h_med = med_fun(g$h), h_lo = ci_h[1], h_hi = ci_h[2],
                 h_p90 = if (any(g$h >= cover_thr)) p90_fun(g$h) else NA)
    }
    r$flag_low_n <- r$n < min_n | r$n_passes < min_passes
    r
  })
  out <- do.call(rbind, out); names(out)[1] <- id; rownames(out) <- NULL
  out[order(out[[id]], match(out$period, names(periods))), ]
}

lidar_change <- function(s, id, from = "pre", to = "post") {
  w <- reshape(s[, setdiff(names(s), "flag_low_n")], idvar = id, timevar = "period", direction = "wide")
  for (m in intersect(c("cover", "h_med", "h_p90", "agbd_mean"), names(s)))
    w[[paste0("d_", m)]] <- w[[paste0(m, ".", to)]] - w[[paste0(m, ".", from)]]
  w
}

lidar_assign <- function(d, polys, id) {
  pts <- sf::st_as_sf(d, coords = c("lon", "lat"), crs = 4326, remove = FALSE)
  pts <- sf::st_transform(pts, sf::st_crs(polys))
  hit <- sf::st_intersects(pts, polys)
  d[[id]] <- polys[[id]][vapply(hit, function(i) if (length(i)) i[1] else NA_integer_, integer(1))]
  d
}

lidar_hexgrid <- function(area, cell_km = 5, crs = NULL) {
  if (!is.null(crs)) area <- sf::st_transform(area, crs)
  if (sf::st_is_longlat(area)) stop("Project 'area' to a metric CRS first (or pass crs =).")
  a <- sf::st_union(area)
  # sf's hexagon 'cellsize' is the flat-to-flat width; this width gives each hexagon the area of a
  # cell_km x cell_km square (cell_km = 5 -> 25 km2 cells)
  g <- sf::st_make_grid(a, cellsize = cell_km * 1000 * sqrt(2 / sqrt(3)), square = FALSE)
  g <- g[lengths(sf::st_intersects(g, a)) > 0]
  hex <- sf::st_sf(cell = seq_along(g), geometry = g)
  suppressWarnings(sf::st_intersection(hex, a))   # clip edge cells to the area
}
