###############################################################################
# 03_extract_plot_als_metrics.R - ALS structural metrics of each 400 m2 PEP plot (11.28 m radius)
#
# Author:    João Paulo Czarnecki de Liz (developer)
# Co-author: Claude (Anthropic), AI coding assistant
# Licence:   MIT (see LICENSE)
#
# Stand-alone version of the plot extraction used to build data/plot_als_metrics.csv. For each plot:
#   1. read a 60 m x 60 m window of its tile around the plot centre (reprojected to the tile's MTM zone);
#   2. remove noise (lidR ivf) and reclassify the ground from scratch (CSF, class_threshold 0.05): the
#      tiles' own classification is not consistent across the province;
#   3. normalise heights with a TIN of the ground returns;
#   4. keep the returns inside the 11.28 m plot circle and between -2 and 60 m above ground (floored at 0);
#      a plot losing > 10 % of its returns to that filter is flagged (failed normalisation), not kept;
#   5. compute the metrics: lidR stdmetrics_z / _i / _rn, VCI, entropy, canopy cover, vertical profile, ...
#
# Input   data/derived/plot_tiles.csv, data/raw/laz/*.LAZ
# Output  data/derived/plot_als_metrics_full.csv (one row per plot; status = "ok" or the failure reason)
# Run     Rscript scripts/03_extract_plot_als_metrics.R                 (all plots with a tile on disk)
#         PLOT_LIMIT=50 WORKERS=6 Rscript scripts/03_extract_plot_als_metrics.R
#   ~1-2 s per plot per worker; checkpointed every 10 x WORKERS plots, so a stopped run resumes.
###############################################################################
suppressPackageStartupMessages({ library(lidR); library(sf); library(parallel); library(data.table) })
ROOT <- Sys.getenv("EXERCISE_ROOT", ".")
LAZ  <- Sys.getenv("LAZ_DIR", file.path(ROOT, "data/raw/laz"))
OUT  <- file.path(ROOT, "data/derived")
WORKERS <- as.integer(Sys.getenv("WORKERS", "6"))
LIMIT   <- as.integer(Sys.getenv("PLOT_LIMIT", "0"))
PLOT_RADIUS_M <- 11.28                 # PEP fixed-radius plot (400 m2)
BUFFER_M      <- 30                    # half-width of the window read and normalised before trimming
MIN_H <- -2; MAX_H <- 60               # plausible heights after normalisation (m)
MAX_OUTLIER_FRACTION <- 0.10           # more than this lost to the height filter = failed normalisation
set.seed(1304)

# ---------------------------------------------------------------- metrics ---------------------------------
nan_to_zero <- function(x) ifelse(is.na(x), 0, x)   # VCI/entropy are NaN for a one-bin canopy: 0 is the answer

aba_metrics <- function(z, i) {
  z <- pmax(z, 0)                       # TIN leaves a few points cm below ground; VCI/entropy fail on z < 0
  zm <- as.list(stdmetrics_z(z)); zm$zentropy <- nan_to_zero(zm$zentropy)
  c(zm, as.list(stdmetrics_i(i)), list(
    vci = nan_to_zero(VCI(z, zmax = max(z), by = 1)),
    entropy = nan_to_zero(entropy(z, by = 1)),
    pzabove5 = sum(z > 5) / length(z)))
}

structure_metrics <- function(x, y, z, rn, nr) {
  z <- pmax(z, 0); n <- length(z); fr <- rn == 1; zr <- max(z) - min(z)
  list(
    rumple_index_pts = tryCatch(rumple_index(x, y, z), error = function(e) NA_real_),
    canopy_cover_2m_fr = if (sum(fr) > 0) sum(z[fr] > 2) / sum(fr) else NA_real_,   # first returns > 2 m
    crr = if (zr > 0) (mean(z) - min(z)) / zr else NA_real_,
    zcv = if (mean(z) != 0) sd(z) / mean(z) else NA_real_,
    entropy_0.5 = nan_to_zero(tryCatch(entropy(z, by = 0.5), error = function(e) NA_real_)),
    entropy_2 = nan_to_zero(tryCatch(entropy(z, by = 2), error = function(e) NA_real_)),
    p_ground_0_0.5 = sum(z >= 0 & z < 0.5) / n, p_understory_0.5_2 = sum(z >= 0.5 & z < 2) / n,
    p_midstory_2_10 = sum(z >= 2 & z < 10) / n, p_overstory_10plus = sum(z >= 10) / n,
    p_vprofile_0_1 = sum(z >= 0 & z < 1) / n, p_vprofile_1_2 = sum(z >= 1 & z < 2) / n,
    p_vprofile_2_4 = sum(z >= 2 & z < 4) / n, p_vprofile_4_8 = sum(z >= 4 & z < 8) / n,
    p_vprofile_8_16 = sum(z >= 8 & z < 16) / n, p_vprofile_16_32 = sum(z >= 16 & z < 32) / n,
    pct_multi_return = sum(nr > 1) / length(nr))
}

all_metrics <- function(x, y, z, i, rn, nr)
  c(aba_metrics(z, i), structure_metrics(x, y, z, rn, nr), as.list(tryCatch(stdmetrics_rn(rn, nr), error = function(e) list())))

# ---------------------------------------------------------------- one plot --------------------------------
process_one_plot <- function(plot_id, longitude, latitude, epsg, tile_path) {
  if (is.na(tile_path) || !file.exists(tile_path)) return(list(plot_id = plot_id, status = "tile_file_missing"))
  xy <- tryCatch(st_coordinates(st_transform(st_sfc(st_point(c(longitude, latitude)), crs = 4326), as.integer(epsg)))[1, ],
                 error = function(e) NULL)
  if (is.null(xy)) return(list(plot_id = plot_id, status = "reprojection_failed"))
  x <- xy[["X"]]; y <- xy[["Y"]]
  las <- tryCatch(readLAS(tile_path, filter = sprintf("-inside %f %f %f %f", x - BUFFER_M, y - BUFFER_M, x + BUFFER_M, y + BUFFER_M)),
                  error = function(e) NULL)
  if (is.null(las) || is.na(npoints(las)) || npoints(las) == 0) return(list(plot_id = plot_id, status = "empty_clip", n_pts_raw = 0L))
  n_raw <- npoints(las); st_crs(las) <- as.integer(epsg)
  las <- tryCatch(classify_noise(las, ivf()), error = function(e) las)
  las <- tryCatch(filter_poi(las, Classification != LASNOISE), error = function(e) las)
  las <- tryCatch(classify_ground(las, csf(class_threshold = 0.05)), error = function(e) NULL)
  if (is.null(las)) return(list(plot_id = plot_id, status = "ground_classify_error", n_pts_raw = n_raw))
  n_ground <- sum(las$Classification == LASGROUND)
  if (n_ground < 10) return(list(plot_id = plot_id, status = "insufficient_ground_points", n_pts_raw = n_raw, n_ground = n_ground))
  las <- tryCatch(normalize_height(las, tin()), error = function(e) NULL)
  if (is.null(las)) return(list(plot_id = plot_id, status = "normalize_failed", n_pts_raw = n_raw, n_ground = n_ground))
  las <- tryCatch(clip_circle(las, x, y, PLOT_RADIUS_M), error = function(e) NULL)
  if (is.null(las) || npoints(las) == 0) return(list(plot_id = plot_id, status = "empty_after_trim", n_pts_raw = n_raw, n_ground = n_ground))
  n_before <- npoints(las)
  las <- tryCatch(filter_poi(las, Z >= MIN_H & Z <= MAX_H), error = function(e) las)
  n_out <- n_before - npoints(las)
  if (npoints(las) == 0) return(list(plot_id = plot_id, status = "empty_after_height_filter", n_pts_raw = n_raw, n_ground = n_ground))
  if (n_out / n_before > MAX_OUTLIER_FRACTION)
    return(list(plot_id = plot_id, status = "excessive_height_outliers", n_pts_raw = n_raw, n_ground = n_ground,
                n_pts_before_height_filter = n_before, n_height_outliers_removed = n_out))
  z <- las$Z
  qc <- list(plot_id = plot_id, status = "ok", n_pts_raw = n_raw, n_ground = n_ground, n_pts_trimmed = length(z),
             n_height_outliers_removed = n_out, pt_density_m2 = length(z) / (pi * PLOT_RADIUS_M^2),
             z_min = min(z), z_max = max(z), z_mean = mean(z), pct_above_2m = mean(z > 2),
             pct_ground_returns = mean(las$Classification == LASGROUND))
  m <- tryCatch(all_metrics(las$X, las$Y, z, las$Intensity, las$ReturnNumber, las$NumberOfReturns), error = function(e) NULL)
  if (is.null(m)) { qc$status <- "metrics_failed"; return(qc) }
  c(qc, m)
}

# ---------------------------------------------------------------- run -------------------------------------
pt <- read.csv(file.path(ROOT, "data/derived/plot_tiles.csv"), stringsAsFactors = FALSE)
pt <- pt[!is.na(pt$tile_file_name) & pt$TYPE_DONNEES == "Données classifiées", ]
pt <- pt[file.exists(file.path(LAZ, pt$tile_file_name)), ]
CK <- file.path(OUT, "plot_als_metrics_full.csv")
done <- if (file.exists(CK)) read.csv(CK)$plot_id else numeric(0)
todo <- pt[!pt$plot_id %in% done, ]
if (LIMIT > 0) todo <- head(todo, LIMIT)
cat("Plots with a tile on disk:", nrow(pt), "| already done:", length(done), "| to do now:", nrow(todo), "\n")

cl <- makeCluster(WORKERS)
clusterEvalQ(cl, { suppressPackageStartupMessages({ library(lidR); library(sf) }); set_lidr_threads(1L); options(lidR.progress = FALSE) })
clusterExport(cl, c("process_one_plot", "all_metrics", "aba_metrics", "structure_metrics", "nan_to_zero",
                    "PLOT_RADIUS_M", "BUFFER_M", "MIN_H", "MAX_H", "MAX_OUTLIER_FRACTION", "LAZ"))
t0 <- Sys.time()
for (ch in split(seq_len(nrow(todo)), ceiling(seq_len(nrow(todo)) / (WORKERS * 10)))) {
  res <- parLapplyLB(cl, ch, function(i, todo) {
    r <- todo[i, ]; process_one_plot(r$plot_id, r$longitude, r$latitude, r$CODE_EPSG, file.path(LAZ, r$tile_file_name))
  }, todo = todo)
  res <- rbindlist(res, fill = TRUE)
  if (file.exists(CK)) res <- rbindlist(list(fread(CK), res), fill = TRUE)
  fwrite(res, CK)
  cat(sprintf("  %d / %d plots (%.1f min)\n", max(ch), nrow(todo), as.numeric(difftime(Sys.time(), t0, units = "mins"))))
}
stopCluster(cl)
out <- fread(CK); print(table(out$status))
