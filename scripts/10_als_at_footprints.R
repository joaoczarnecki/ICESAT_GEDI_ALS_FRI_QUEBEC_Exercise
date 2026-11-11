###############################################################################
# 10_als_at_footprints.R - airborne lidar (ALS) equivalents of the ICESat-2 and GEDI metrics, computed on the
# exact ground each satellite sample covers, in the ALS tiles that hold the PEP plots of the UPE 14-15 region.
#
# Author:    João Paulo Czarnecki de Liz (developer)
# Co-author: Claude (Anthropic), AI coding assistant
# Licence:   MIT (see LICENSE)
#
# For every tile: read the LAZ (provider classification: 2 = ground), normalise heights with a TIN of the
# ground returns, floor heights at 0 and drop returns above 60 m, then clip
#   * each GEDI footprint: circle of 12.5 m radius around the shot centre
#   * each ATL08 segment:  rectangle 100 m along track x 14 m across, centred on the segment
#   * each PEP plot:       circle of 11.28 m (check against data/plot_als_metrics.csv, which used CSF ground)
# and compute the ALS version of each satellite metric:
#   GEDI RHxx      <-> ALS percentile xx of ALL return heights (ground included; RH is relative to the ground
#                      return, like the ALS heights) - als_rh10 ... als_rh100
#   ATL08 h_canopy <-> ALS 98th percentile of CANOPY returns (> 0.5 m, where ATL08 starts calling photons canopy),
#                      als_p98_can; ch_p50 <-> als_p50_can; h_mean_canopy <-> als_mean_can; same with > 2 m in
#                      als_*_can2; segment with no canopy photons <-> fewer than 3 canopy returns
#   cover          <-> ALS first returns > 2 m / all first returns (als_cover2); > 5 m (als_cover5)
#
# Input   data/derived/why/tiles_upe.csv, samples_gedi.csv, samples_atl08.csv, plots_upe.csv (09_footprint_inputs.py)
# Output  data/derived/why/als_at_gedi.csv, als_at_atl08.csv, als_at_plots_check.csv, als_tile_wall_to_wall.csv
#         (1 m CHM summary per tile) and als_cache/<tile>_chm_dm.tif (the CHM, in decimetres)
# Run     WORKERS=6 Rscript scripts/10_als_at_footprints.R           (~4.5 h for 306 tiles, 23.5 GB of LAZ;
#         one cache file per tile, so it resumes after a stop)
#         TILE_LIMIT=3 Rscript scripts/10_als_at_footprints.R        (a quick try on 3 tiles)
###############################################################################
suppressPackageStartupMessages({ library(lidR); library(data.table); library(parallel) })
ROOT <- Sys.getenv("EXERCISE_ROOT", ".")
WORKERS <- as.integer(Sys.getenv("WORKERS", "6"))
NTILES  <- as.integer(Sys.getenv("TILE_LIMIT", "0")); if (NTILES <= 0) NTILES <- Inf
OUT <- Sys.getenv("WHY_DIR", file.path(ROOT, "data/derived/why"))
CACHE <- Sys.getenv("WHY_CACHE", file.path(OUT, "als_cache")); dir.create(CACHE, showWarnings = FALSE, recursive = TRUE)

tiles <- fread(file.path(OUT, "tiles_upe.csv"))
gedi  <- fread(file.path(OUT, "samples_gedi.csv"),  select = c("time", "beam", "tile_file_name", "x_tile", "y_tile"), colClasses = list(character = "time"))
atl   <- fread(file.path(OUT, "samples_atl08.csv"), select = c("time_ns", "rgt", "cycle", "gt", "segment_id_beg",
                                                               "tile_file_name", "x_tile", "y_tile", "ux", "uy"), colClasses = list(character = "time_ns"))
plots <- fread(file.path(OUT, "plots_upe.csv"), select = c("plot_id", "tile_file_name", "latitude", "longitude",
                                                           "CODE_EPSG"))
tiles <- tiles[order(-(tile_file_name %in% c(gedi$tile_file_name, atl$tile_file_name)))]
if (is.finite(NTILES)) tiles <- tiles[seq_len(min(NTILES, .N))]

one_tile <- function(t, gedi, atl, plots, CACHE) {
  suppressPackageStartupMessages({ library(lidR); library(data.table); library(sf) })
  set_lidr_threads(1L); options(lidR.progress = FALSE)
  f <- file.path(CACHE, sub("\\.LAZ$", ".rds", t$tile_file_name))
  if (file.exists(f) && identical(readRDS(f)$version, 2L)) return(f)   # reuse caches of this version only
  t0 <- Sys.time()
  g <- gedi[tile_file_name == t$tile_file_name]; a <- atl[tile_file_name == t$tile_file_name]
  p <- plots[tile_file_name == t$tile_file_name]
  las <- readLAS(t$path, select = "xyzrnc", filter = "-drop_withheld -drop_class 7 18")
  res <- list(tile = t$tile_file_name, version = 2L, status = "ok", gedi = NULL, atl = NULL, plots = NULL)
  if (is.empty(las) || sum(las$Classification == 2L) < 100) {
    res$status <- "no_ground"; saveRDS(res, f); return(f)
  }
  las <- normalize_height(las, tin(), use_class = 2L)
  las <- filter_poi(las, Z >= -2, Z <= 60)
  las$Z[las$Z < 0] <- 0
  # GEDI-like metrics: percentiles of all returns, first-return cover
  mg <- function(z, rn) {
    q <- quantile(z, c(.10, .25, .50, .75, .90, .95, .98, 1), names = FALSE)
    fr <- z[rn == 1L]
    list(als_n = length(z), als_rh10 = q[1], als_rh25 = q[2], als_rh50 = q[3], als_rh75 = q[4], als_rh90 = q[5],
         als_rh95 = q[6], als_rh98 = q[7], als_rh100 = q[8],
         als_cover2 = if (length(fr)) mean(fr > 2) else NA_real_, als_cover5 = if (length(fr)) mean(fr > 5) else NA_real_,
         als_frac2 = mean(z > 2))
  }
  # ATL08-like metrics: percentiles of canopy returns. ATL08 labels photons from ~0.5 m above the ground as
  # canopy (median h_min_canopy 0.64 m here), so returns > 0.5 m are the main counterpart; > 2 m kept to compare
  ma <- function(z, rn) {
    fr <- z[rn == 1L]
    can <- function(thr, sfx) {
      cz <- z[z > thr]
      qc <- if (length(cz) >= 3) quantile(cz, c(.25, .50, .75, .98), names = FALSE) else rep(NA_real_, 4)
      setNames(list(length(cz), qc[1], qc[2], qc[3], qc[4], if (length(cz) >= 3) mean(cz) else NA_real_),
               paste0(c("als_n_can", "als_p25_can", "als_p50_can", "als_p75_can", "als_p98_can", "als_mean_can"), sfx))
    }
    c(list(als_n = length(z)), can(0.5, ""), can(2, "2"),
      list(als_max = max(z), als_p98_all = quantile(z, .98, names = FALSE),
           als_cover2 = if (length(fr)) mean(fr > 2) else NA_real_, als_cover5 = if (length(fr)) mean(fr > 5) else NA_real_,
           als_frac2 = mean(z > 2)))
  }
  run_clips <- function(clips, fun) rbindlist(lapply(clips, function(l) {
    if (is.null(l) || is.empty(l)) return(data.table(als_n = 0L)) else as.data.table(fun(l$Z, l$ReturnNumber))
  }), fill = TRUE)
  if (nrow(g)) {
    cl <- clip_circle(las, g$x_tile, g$y_tile, 12.5)
    if (inherits(cl, "LAS")) cl <- list(cl)
    res$gedi <- cbind(g[, .(time, beam)], run_clips(cl, mg))
  }
  if (nrow(a)) {
    rect <- lapply(seq_len(nrow(a)), function(i) {
      cx <- a$x_tile[i]; cy <- a$y_tile[i]; ux <- a$ux[i]; uy <- a$uy[i]; L <- 50; W <- 7
      m <- rbind(c(cx - L * ux - W * uy, cy - L * uy + W * ux), c(cx + L * ux - W * uy, cy + L * uy + W * ux),
                 c(cx + L * ux + W * uy, cy + L * uy - W * ux), c(cx - L * ux + W * uy, cy - L * uy - W * ux))
      st_polygon(list(rbind(m, m[1, ])))
    })
    cl <- clip_roi(las, st_sfc(rect, crs = st_crs(las)))
    if (inherits(cl, "LAS")) cl <- list(cl)
    res$atl <- cbind(a[, .(time_ns, rgt, cycle, gt, segment_id_beg)], run_clips(cl, ma))
  }
  if (nrow(p)) {
    xy <- st_coordinates(st_transform(st_as_sf(p, coords = c("longitude", "latitude"), crs = 4326), st_crs(las)))
    cl <- clip_circle(las, xy[, 1], xy[, 2], 11.28)
    if (inherits(cl, "LAS")) cl <- list(cl)
    res$plots <- cbind(p[, .(plot_id)], run_clips(cl, mg))
  }
  # wall-to-wall reference for the tile: 1 m canopy height model (highest return per cell) and first returns
  chm <- rasterize_canopy(las, res = 1, algorithm = p2r(0.2))
  v <- terra::values(chm, mat = FALSE); v <- v[!is.na(v)]
  fr <- las$Z[las$ReturnNumber == 1L]
  res$tile_stats <- data.table(chm_cells = length(v), chm_cover2 = mean(v > 2), chm_cover5 = mean(v > 5),
                               chm_med_can = median(v[v > 2]), chm_p90_can = quantile(v[v > 2], 0.9, names = FALSE),
                               fr_cover2 = mean(fr > 2), fr_cover5 = mean(fr > 5), n_points = npoints(las))
  terra::writeRaster(round(chm * 10), file.path(CACHE, sub("\\.LAZ$", "_chm_dm.tif", t$tile_file_name)),
                     datatype = "INT2U", gdal = c("COMPRESS=DEFLATE"), overwrite = TRUE)
  res$seconds <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  saveRDS(res, f); rm(las); gc(verbose = FALSE)
  f
}

cat(sprintf("%d tiles, %d GEDI shots, %d ATL08 segments, %d plots; %d workers\n",
            nrow(tiles), nrow(gedi), nrow(atl), nrow(plots), WORKERS))
tl <- split(tiles, seq_len(nrow(tiles)))
t_start <- Sys.time()
if (WORKERS > 1) {
  cl <- makeCluster(WORKERS)
  files <- parLapplyLB(cl, tl, one_tile, gedi = gedi, atl = atl, plots = plots, CACHE = CACHE)
  stopCluster(cl)
} else files <- lapply(tl, one_tile, gedi = gedi, atl = atl, plots = plots, CACHE = CACHE)
cat(sprintf("extraction: %.1f min\n", as.numeric(difftime(Sys.time(), t_start, units = "mins"))))

R <- lapply(unlist(files), readRDS)
cat("tile status:", paste(names(table(sapply(R, `[[`, "status"))), table(sapply(R, `[[`, "status")), collapse = " "),
    "| median s per tile:", round(median(unlist(lapply(R, `[[`, "seconds")), na.rm = TRUE), 1), "\n")
bind <- function(k) rbindlist(lapply(R, function(r) if (!is.null(r[[k]])) cbind(tile_file_name = r$tile, r[[k]])), fill = TRUE)
fwrite(bind("gedi"),  file.path(OUT, "als_at_gedi.csv"))
fwrite(bind("atl"),   file.path(OUT, "als_at_atl08.csv"))
fwrite(bind("plots"), file.path(OUT, "als_at_plots_check.csv"))
fwrite(bind("tile_stats"), file.path(OUT, "als_tile_wall_to_wall.csv"))
cat("wrote als_at_gedi.csv, als_at_atl08.csv, als_at_plots_check.csv, als_tile_wall_to_wall.csv\n")
