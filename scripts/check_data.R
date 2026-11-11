###############################################################################
# check_data.R - check the inputs and outputs of each step before moving on
#
# Author:    João Paulo Czarnecki de Liz (developer)
# Co-author: Claude (Anthropic), AI coding assistant
# Licence:   MIT (see LICENSE)
#
# Every check prints PASS, WARN or FAIL with a one-line reason. FAIL = the next step will not work or its results
# would be wrong; WARN = it will run, but look at the reason. Steps whose files are absent are reported as SKIP.
#
# Run   Rscript scripts/check_data.R          all steps whose files are present
#       Rscript scripts/check_data.R 5        one step (0 = software, 1-11 = the numbered scripts)
# Use   source("scripts/check_data.R"); check_step(3)          (from R or the R Markdown exercise)
###############################################################################
suppressPackageStartupMessages({ library(data.table) })
ROOT <- Sys.getenv("EXERCISE_ROOT", ".")
f_ <- function(...) file.path(ROOT, ...)
PEP_GPKG <- Sys.getenv("PEP_GPKG", f_("data/raw/PEP.gpkg"))
IDX_GPKG <- Sys.getenv("LIDAR_INDEX_GPKG", f_("data/raw/Index_Lidar.gpkg"))
LAZ_DIR  <- Sys.getenv("LAZ_DIR", f_("data/raw/laz"))
PY <- Sys.getenv("PY", if (.Platform$OS.type == "windows") f_(".venv/Scripts/python.exe") else f_(".venv/bin/python"))

.res <- NULL
chk <- function(step, what, ok, msg = "", warn = FALSE) {
  status <- if (isTRUE(ok)) "PASS" else if (warn) "WARN" else "FAIL"
  .res <<- rbind(.res, data.frame(step = step, status = status, check = what, detail = msg))
  cat(sprintf("  [%s] %s%s\n", status, what, if (nzchar(msg)) paste0(" - ", msg) else ""))
  invisible(isTRUE(ok))
}
skip <- function(step, what) { .res <<- rbind(.res, data.frame(step = step, status = "SKIP", check = what, detail = "file not found"))
  cat(sprintf("  [SKIP] %s - file not found\n", what)) }
has_cols <- function(d, cols) { m <- setdiff(cols, names(d)); if (length(m)) paste("missing:", paste(m, collapse = ", ")) else "" }
pct <- function(x) sprintf("%.1f%%", 100 * x)
als_table <- function() {                          # the ALS table actually used downstream
  full <- f_("data/derived/plot_als_metrics_full.csv")
  if (file.exists(full)) list(d = fread(full), src = full, own = TRUE) else list(d = fread(f_("data/plot_als_metrics.csv")), src = "data/plot_als_metrics.csv", own = FALSE)
}

why_dir <- function() {                            # step 9-10 tables: yours, else the provided ones
  w <- Sys.getenv("WHY_DIR", f_("data/derived/why"))
  if (file.exists(file.path(w, "plots_upe.csv"))) w else f_("data/why")
}

check_step <- function(step) {
  cat(sprintf("\nStep %s\n", step))
  switch(as.character(step),
  "0" = {
    pk <- c("lidR", "RCSF", "sf", "curl", "data.table", "ggplot2", "patchwork", "scales", "rnaturalearth", "rnaturalearthhires")
    miss <- pk[!vapply(pk, requireNamespace, logical(1), quietly = TRUE)]
    chk(0, "R packages", !length(miss), if (length(miss)) paste("install:", paste(miss, collapse = ", ")) else paste(length(pk), "found"))
    if (!file.exists(PY)) chk(0, "Python", FALSE, sprintf("not found at %s (create .venv or set PY=/path/to/python)", PY))
    else {
      out <- tryCatch(system2(PY, c("-I", "-c", shQuote("import sliderule, geopandas, pyarrow; print(sliderule.__version__, geopandas.__version__)")),
                              stdout = TRUE, stderr = TRUE), error = function(e) conditionMessage(e))
      chk(0, "Python packages (sliderule, geopandas, pyarrow)", is.null(attr(out, "status")), paste(tail(out, 1)))
    }
  },
  "1" = {
    if (!file.exists(PEP_GPKG)) skip(1, "data/raw/PEP.gpkg") else {
      ly <- sf::st_layers(PEP_GPKG)$name
      chk(1, "PEP.gpkg layers", all(c("placette", "placette_mes", "dendro_arbres", "classi_eco_pe") %in% ly),
          has_cols(setNames(as.list(ly), ly), c("placette", "placette_mes", "dendro_arbres", "classi_eco_pe")))
    }
    if (!file.exists(IDX_GPKG)) skip(1, "data/raw/Index_Lidar.gpkg (only needed to rebuild the ALS table)") else {
      ly <- sf::st_layers(IDX_GPKG)
      chk(1, "Index_Lidar.gpkg has layer Index_Tuiles_LiDAR", "Index_Tuiles_LiDAR" %in% ly$name)
    }
    pt <- f_("data/derived/plot_tiles.csv")
    if (!file.exists(pt)) skip(1, "data/derived/plot_tiles.csv") else {
      d <- fread(pt)
      chk(1, "plot_tiles.csv columns", has_cols(d, c("plot_id", "NOM_TUILE", "CODE_EPSG", "DATES_ACQUISITION", "url", "TYPE_DONNEES")) == "",
          has_cols(d, c("plot_id", "NOM_TUILE", "CODE_EPSG", "DATES_ACQUISITION", "url", "TYPE_DONNEES")))
      chk(1, "one row per plot", !anyDuplicated(d$plot_id), sprintf("%s plots", format(nrow(d), big.mark = ",")))
      chk(1, "plots with a tile", mean(!is.na(d$NOM_TUILE)) > 0.8, pct(mean(!is.na(d$NOM_TUILE))), warn = TRUE)
      e <- unique(na.omit(d$CODE_EPSG))
      chk(1, "EPSG codes are Quebec MTM zones (2943-2952)", all(e >= 2943 & e <= 2952), paste(sort(e), collapse = " "))
      chk(1, "download URLs", all(grepl("^https?://", na.omit(d$url))), "")
    }
  },
  "2" = {
    pt <- f_("data/derived/plot_tiles.csv")
    if (!dir.exists(LAZ_DIR) || !file.exists(pt)) skip(2, "data/raw/laz/ and plot_tiles.csv") else {
      d <- fread(pt)[!is.na(tile_file_name) & TYPE_DONNEES == "Données classifiées"]
      need <- unique(d$tile_file_name); have <- file.exists(file.path(LAZ_DIR, need))
      chk(2, "tiles on disk", all(have), sprintf("%s of %s", format(sum(have), big.mark = ","), format(length(need), big.mark = ",")), warn = TRUE)
      sz <- file.info(file.path(LAZ_DIR, need[have]))$size
      chk(2, "no empty file", !any(sz == 0), sprintf("%d empty", sum(sz == 0)))
      if (any(have)) {
        s <- sample(need[have], min(3, sum(have)))
        ok <- vapply(s, function(f) !inherits(tryCatch(lidR::readLASheader(file.path(LAZ_DIR, f)), error = function(e) e), "error"), logical(1))
        chk(2, "LAZ headers readable (3 random tiles)", all(ok), paste(s[!ok], collapse = ", "))
      }
    }
  },
  "3" = {
    a <- als_table(); d <- a$d
    cat("  using", a$src, "\n")
    chk(3, "ALS columns", has_cols(d, c("plot_id", "zq50", "zq95", "zmax", "pt_density_m2")) == "", has_cols(d, c("plot_id", "zq50", "zq95", "zmax", "pt_density_m2")))
    if ("status" %in% names(d)) {
      chk(3, "plots with status ok", mean(d$status == "ok") > 0.9, pct(mean(d$status == "ok")), warn = TRUE)
      cat("  status:", paste(names(table(d$status)), table(d$status), collapse = "; "), "\n")
      d <- d[status == "ok"]
    }
    chk(3, "heights within 0-60 m", all(d$zq95 >= 0 & d$zmax <= 60, na.rm = TRUE), sprintf("zq95 %.1f-%.1f m", min(d$zq95), max(d$zq95)))
    chk(3, "zq50 <= zq95 <= zmax", all(d$zq50 <= d$zq95 + 1e-9 & d$zq95 <= d$zmax + 1e-9, na.rm = TRUE), "")
    chk(3, "point density", median(d$pt_density_m2) > 1, sprintf("median %.1f pts/m2 in the plots", median(d$pt_density_m2)), warn = TRUE)
  },
  "4" = {
    b <- f_("data/derived/plot_buffers_150m.gpkg")
    if (!file.exists(b)) skip(4, "data/derived/plot_buffers_150m.gpkg") else {
      g <- sf::st_read(b, quiet = TRUE); a <- als_table()$d; if ("status" %in% names(a)) a <- a[status == "ok"]
      chk(4, "one buffer per plot with ALS", nrow(g) == nrow(a) && !anyDuplicated(g$plot_id), sprintf("%s buffers, %s plots", nrow(g), nrow(a)))
      ar <- as.numeric(sf::st_area(sf::st_transform(g[sample(nrow(g), min(200, nrow(g))), ], 32198)))
      chk(4, "buffer area = pi x 150^2", all(abs(ar / (pi * 150^2) - 1) < 0.02), sprintf("%.0f m2 (median)", median(ar)))
      chk(4, "valid geometries", all(sf::st_is_valid(g)), "")
    }
  },
  "5" = {
    a <- als_table()$d
    for (p in c("gedi02a", "atl08")) {
      f <- f_("data/derived", paste0(p, "_plots.csv")); if (!file.exists(f)) f <- f_("data/satellite", paste0(p, "_plots.csv"))
      if (!file.exists(f)) { skip(5, paste0(p, "_plots.csv")); next }
      d <- fread(f, colClasses = list(character = intersect(c("time", "time_ns"), names(fread(f, nrows = 1)))))
      need <- if (p == "gedi02a") c("plot_id", "time", "beam", "orbit", "rh50", "rh95", "rh98", "sensitivity", "leaf_off_flag", "flags", "lon", "lat")
              else c("plot_id", "time_ns", "rgt", "gt", "spot", "h_canopy", "segment_snowcover", "lon", "lat")
      chk(5, paste(p, "columns"), has_cols(d, need) == "", has_cols(d, need))
      chk(5, paste(p, "plot_id all in the ALS table"), all(d$plot_id %in% a$plot_id), sprintf("%s rows, %s plots", format(nrow(d), big.mark = ","), format(uniqueN(d$plot_id), big.mark = ",")))
      tcol <- if (p == "gedi02a") "time" else "time_ns"
      yr <- as.integer(substr(d[[tcol]], 1, 4)); mo <- as.integer(substr(d[[tcol]], 6, 7))
      chk(5, paste(p, "years 2019-2025"), all(yr >= 2018 & yr <= 2025), paste(range(yr), collapse = "-"))
      chk(5, paste(p, "months June-September"), mean(mo %in% 6:9) > 0.98, sprintf("%s outside (granules selected by date)", pct(mean(!mo %in% 6:9))), warn = TRUE)
      key <- if (p == "gedi02a") c("plot_id", "time", "beam") else c("plot_id", "time_ns", "rgt", "gt", "segment_id_beg")
      chk(5, paste(p, "no duplicated sample x plot"), !anyDuplicated(d[, intersect(key, names(d)), with = FALSE]), "")
      if (p == "gedi02a") {
        chk(5, "GEDI south of 51.6 N", all(d$lat <= 51.7), sprintf("max lat %.2f", max(d$lat)))
        chk(5, "GEDI server filters applied (flags: bit 0 off, bit 1 on)", all(bitwAnd(d$flags, 1L) == 0 & bitwAnd(d$flags, 2L) == 2), "")
        chk(5, "GEDI RH95 within -5..60 m", mean(d$rh95 >= -5 & d$rh95 <= 60) > 0.99, sprintf("%.2f%% outside", 100 * mean(!(d$rh95 >= -5 & d$rh95 <= 60))), warn = TRUE)
      } else {
        chk(5, "ATL08 h_canopy within 0..60 m (or NA = no canopy)", mean(is.na(d$h_canopy) | (d$h_canopy >= 0 & d$h_canopy <= 60)) > 0.99, "", warn = TRUE)
      }
      cache <- f_("data/derived", paste0(p, "_plots_cache"))
      if (dir.exists(cache)) chk(5, paste(p, "download chunks cached"), TRUE, sprintf("%d chunks", length(list.files(cache, "_20[0-9]{2}[.]parquet$"))))
    }
  },
  "6" = {
    f <- f_("data/derived/plot_mrnf_events.csv"); if (!file.exists(f)) f <- f_("data/plot_mrnf_events.csv")
    d <- fread(f); a <- als_table()$d
    cat("  using", f, "\n")
    chk(6, "event columns", has_cols(d, c("plot_id", "layer", "exercice", "origine", "an_origine", "perturb", "an_perturb", "overlap")) == "",
        has_cols(d, c("plot_id", "layer", "exercice", "origine", "an_origine", "perturb", "an_perturb", "overlap")))
    chk(6, "overlap in [0, 1]", all(d$overlap >= 0 & d$overlap <= 1),
        sprintf("%d slivers round to 0; step 7 keeps events covering >= 50%% of the plot", sum(d$overlap == 0)))
    chk(6, "plot_id all in the ALS table", all(d$plot_id %in% a$plot_id), sprintf("%s events on %s plots", format(nrow(d), big.mark = ","), format(uniqueN(d$plot_id), big.mark = ",")))
    chk(6, "known layers", all(d$layer %in% c("ca_interv_for_close_scale", "ca_feu_close_scale", "ca_perturb_autre_close_scale")), "")
  },
  "7" = {
    f <- f_("data/derived/plots_province.csv")
    if (!file.exists(f)) skip(7, "data/derived/plots_province.csv") else {
      d <- fread(f); a <- als_table()$d; if ("status" %in% names(a)) a <- a[status == "ok"]
      chk(7, "one row per plot with ALS", nrow(d) == nrow(a) && !anyDuplicated(d$plot_id), sprintf("%s rows", format(nrow(d), big.mark = ",")))
      chk(7, "forest type assigned", mean(!is.na(d$forest_type)) > 0.95, pct(mean(!is.na(d$forest_type))), warn = TRUE)
      cat("  forest types:", paste(names(table(d$forest_type)), table(d$forest_type), collapse = "; "), "\n")
      chk(7, "ALS dates 2009-2025", all(d$als_year >= 2009 & d$als_year <= 2025), paste(range(d$als_year), collapse = "-"))
      chk(7, "field measurement near the ALS", median(abs(d$field_year - d$als_year), na.rm = TRUE) <= 6,
          sprintf("median %d years apart", as.integer(median(abs(d$field_year - d$als_year), na.rm = TRUE))), warn = TRUE)
      e <- f_("data/derived/plot_events_2010plus.csv")
      if (file.exists(e)) chk(7, "events since 2010", TRUE, sprintf("%s plots", format(uniqueN(fread(e)$plot_id), big.mark = ",")))
    }
  },
  "8" = {
    figs <- f_("docs/assets/img", paste0(c("P1_plots_with_samples", "P2_agreement_at_the_plot", "P3_delay_uncertainty", "P4_forest_type_and_als_season"), ".png"))
    chk(8, "figures written", all(file.exists(figs)), paste(basename(figs[!file.exists(figs)]), collapse = ", "))
    n <- f_("outputs/numbers.txt")
    if (!file.exists(n)) skip(8, "outputs/numbers.txt") else {
      x <- readLines(n); chk(8, "numbers written", length(x) > 10, sprintf("%d lines", length(x)))
      for (p in c("pairs_gedi.csv", "pairs_atl08.csv")) if (file.exists(f_("outputs", p))) {
        d <- fread(f_("outputs", p)); chk(8, paste(p, "distances <= 100 m"), all(d$dist <= 100), sprintf("%s pairs", format(nrow(d), big.mark = ",")))
      }
    }
  },
  "9" = {
    chk(9, "study area polygon", file.exists(f_("data/study_area/upe1415_study_area.shp")))
    W <- why_dir()
    for (s in c("gedi02a.csv", "atl08.csv")) {
      p <- file.path(Sys.getenv("WHY_SAT_DIR", f_("data/derived/why")), s)
      if (!file.exists(p)) skip(9, paste("region satellite download", s, "(only needed to rebuild step 9)"))
      else chk(9, paste("region download", s), nrow(fread(p, select = 1L)) > 1000, sprintf("%s rows", format(nrow(fread(p, select = 1L)), big.mark = ",")))
    }
    if (!file.exists(file.path(W, "plots_upe.csv"))) skip(9, file.path(W, "plots_upe.csv")) else {
      p <- fread(file.path(W, "plots_upe.csv")); t <- fread(file.path(W, "tiles_upe.csv"))
      chk(9, "region plots with ALS and forest type", nrow(p) > 300 && !anyNA(p$forest_type), sprintf("%d plots in %d tiles", nrow(p), nrow(t)))
      chk(9, "every plot's tile is listed", all(p$tile_file_name %in% t$tile_file_name))
      g <- fread(file.path(W, "samples_gedi.csv"), select = c("tile_file_name", "x_tile", "y_tile", "post_als_event"))
      a <- fread(file.path(W, "samples_atl08.csv"), select = c("tile_file_name", "ux", "uy", "post_als_event"))
      tg <- merge(g, t[, .(tile_file_name, hdr_xmin, hdr_xmax, hdr_ymin, hdr_ymax)], by = "tile_file_name")
      chk(9, "GEDI footprints wholly inside their tile",
          all(tg$x_tile - 12.5 >= tg$hdr_xmin & tg$x_tile + 12.5 <= tg$hdr_xmax & tg$y_tile - 12.5 >= tg$hdr_ymin & tg$y_tile + 12.5 <= tg$hdr_ymax),
          sprintf("%s footprints", format(nrow(g), big.mark = ",")))
      chk(9, "ATL08 along-track direction is a unit vector", all(abs(sqrt(a$ux^2 + a$uy^2) - 1) < 1e-3), sprintf("%s segments", format(nrow(a), big.mark = ",")))
      chk(9, "post-ALS events flagged", mean(g$post_als_event != "none") < 0.2, sprintf("GEDI %s with an event", pct(mean(g$post_als_event != "none"))), warn = TRUE)
    }
  },
  "10" = {
    W <- why_dir()
    if (!file.exists(file.path(W, "als_at_gedi.csv"))) skip(10, file.path(W, "als_at_gedi.csv")) else {
      g <- fread(file.path(W, "als_at_gedi.csv")); s <- fread(file.path(W, "samples_gedi.csv"), select = "time")
      chk(10, "ALS computed for the GEDI footprints", nrow(g) / nrow(s) > 0.95, sprintf("%s of %s", format(nrow(g), big.mark = ","), format(nrow(s), big.mark = ",")), warn = TRUE)
      chk(10, "GEDI footprints with enough ALS returns", mean(g$als_n >= 100, na.rm = TRUE) > 0.95, pct(mean(g$als_n >= 100, na.rm = TRUE)), warn = TRUE)
      a <- fread(file.path(W, "als_at_atl08.csv"))
      chk(10, "ALS heights within 0-60 m", all(between(c(g$als_rh98, a$als_p98_can), 0, 60), na.rm = TRUE))
      pc <- merge(fread(file.path(W, "als_at_plots_check.csv")), als_table()$d[, .(plot_id, zq95)], by = "plot_id")
      e <- sqrt(mean((pc$als_rh95 - pc$zq95)^2, na.rm = TRUE))
      chk(10, "plot P95 matches the ALS table (same LAZ, other ground filter)", e < 0.5, sprintf("RMSE %.2f m over %d plots", e, nrow(pc)))
    }
  },
  "11" = {
    figs <- f_("docs/assets/img/why", paste0(c("13_footprint_agreement", "17_plot_level_comparison"), ".png"))
    chk(11, "figures written", all(file.exists(figs)), paste(basename(figs[!file.exists(figs)]), collapse = ", "))
    n <- f_("outputs/why/numbers_why.txt")
    if (!file.exists(n)) skip(11, "outputs/why/numbers_why.txt") else {
      fa <- fread(f_("outputs/why/footprint_agreement.csv"))
      chk(11, "footprint agreement for 8 metrics", nrow(fa) == 8 && all(fa$n > 1000), sprintf("GEDI RH98 RMSE %.1f m", fa[metric == "rh98"]$rmse))
    }
  })
  invisible(.res[.res$step == step, ])
}

if (sys.nframe() == 0) {
  a <- commandArgs(trailingOnly = TRUE)
  steps <- if (length(a)) as.integer(a) else 0:11
  for (s in steps) check_step(s)
  cat(sprintf("\n%d PASS, %d WARN, %d FAIL, %d SKIP\n", sum(.res$status == "PASS"), sum(.res$status == "WARN"),
              sum(.res$status == "FAIL"), sum(.res$status == "SKIP")))
  if (any(.res$status == "FAIL")) quit(status = 1)
}
