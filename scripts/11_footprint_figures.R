###############################################################################
# 11_footprint_figures.R - ICESat-2 and GEDI against airborne lidar (ALS) on the same ground, in the UPE 14-15
# region: the "why" behind the plot-level results of steps 5-6 (docs/06_why_on_the_same_ground.md).
#
# Author:    João Paulo Czarnecki de Liz (developer)
# Co-author: Claude (Anthropic), AI coding assistant
# Licence:   MIT (see LICENSE)
#
# Three levels of comparison, from the most to the least like-for-like:
#   footprint  satellite metric vs the ALS version of the same metric on the same ground (10_als_at_footprints.R)
#   plot       ALS metrics of the 400 m2 PEP plot (data/plot_als_metrics.csv) vs satellite samples within r m
#   tile       polygon metrics (cover_tall, h_med) for the ALS tiles vs the same from ALS, and vs the wall-to-wall
#              ALS canopy height model
# Periods: ALS flown in 2017 (1 Aug-1 Oct, leaf-on) and 2018 (30 May-12 Jun, leaf-out); field remeasurement
# 2019-2021; satellites June-September 2019-2025. Footprints cut or harvested between the ALS flight and the
# satellite date (MRNF polygons) are kept apart.
# Forest type: from the field tree tally (live basal area); for a footprint, the type of the nearest PEP plot
# when that plot is within 250 m (otherwise no type).
#
# Input   data/derived/why/* (09 and 10), data/study_area/upe1415_study_area.shp
# Output  docs/assets/img/why/11-18_*.png, outputs/why/numbers_why.txt, outputs/why/*.csv
# Run     Rscript scripts/11_footprint_figures.R      (~5 min)
###############################################################################
suppressPackageStartupMessages({
  library(sf); library(ggplot2); library(patchwork); library(dplyr); library(tidyr); library(scales)
  library(data.table); library(terra); library(lidR)
})
sf_use_s2(FALSE); options(lidR.progress = FALSE); invisible(Sys.setlocale("LC_TIME", "C"))
ROOT <- Sys.getenv("EXERCISE_ROOT", ".")
AD   <- Sys.getenv("WHY_DIR", if (file.exists(file.path(ROOT, "data/derived/why/als_at_gedi.csv")))
  file.path(ROOT, "data/derived/why") else file.path(ROOT, "data/why"))   # tables of 09 and 10: yours, else the provided ones
CHMD <- Sys.getenv("WHY_CACHE", file.path(AD, "als_cache"))                 # per-tile CHMs written by 10
FIG  <- Sys.getenv("WHY_FIG", file.path(ROOT, "docs/assets/img/why")); OUTC <- Sys.getenv("WHY_OUT", file.path(ROOT, "outputs/why"))
dir.create(FIG, showWarnings = FALSE, recursive = TRUE); dir.create(OUTC, showWarnings = FALSE, recursive = TRUE)
source(file.path(ROOT, "scripts/summarise_lidar_by_polygon.R"))           # boot_pass()
set.seed(42)
NUM <- file.path(OUTC, "numbers_why.txt"); cat("", file = NUM)
say <- function(...) { s <- sprintf(...); cat(s, "\n"); cat(s, "\n", file = NUM, append = TRUE) }

# --- look ------------------------------------------------------------------------------------
SENSOR <- c("ICESat-2 ATL08" = "#2a78d6", "GEDI L2A" = "#eb6834")
SENS_LEV <- c("GEDI L2A", "ICESat-2 ATL08")                                 # facet order
H_PAL  <- c("#eef6e9", "#b9dcaa", "#74b96a", "#2f8a3e", "#0d5226")
FT_PAL <- c("Softwood" = "#1f7a4d", "Mixed" = "#7d55d0", "Hardwood" = "#c47a00", "Open / regenerating" = "#8e8e8e")
KEEP_PAL <- c("Kept by default" = "#333333", "Dropped by default" = "#b07d00")
DIST_PAL <- c("No event" = "#333333", "Partial cut / tending" = "#c47a00", "Harvest (stand-replacing)" = "#c2479a")
INK2 <- "grey35"
theme_set(theme_minimal(base_size = 10) +
            theme(panel.grid.minor = element_blank(), plot.title = element_text(face = "bold", size = 12),
                  plot.title.position = "plot", plot.subtitle = element_text(colour = INK2),
                  plot.caption = element_text(colour = INK2, hjust = 0), strip.text = element_text(face = "bold")))
save <- function(p, f, w, h) { ggsave(file.path(FIG, f), p, width = w, height = h, dpi = 200, bg = "white"); cat("  wrote", f, "\n") }
fmt <- function(x, d = 0) formatC(x, format = "f", digits = d, big.mark = ",")
stats_pair <- function(s, a) {
  ok <- is.finite(s) & is.finite(a); s <- s[ok]; a <- a[ok]; d <- s - a
  data.table(n = length(d), r = cor(s, a), bias = mean(d), med_bias = median(d), rmse = sqrt(mean(d^2)),
             mae = mean(abs(d)), within3 = mean(abs(d) <= 3))
}
stat_lab <- function(st, unit = "m") sprintf("n = %s\nr = %.2f\nbias = %+.1f %s\nRMSE = %.1f %s", fmt(st$n), st$r, st$bias, unit, st$rmse, unit)
ci <- function(x, pass, fun = mean, B = 400) { b <- as.numeric(boot_pass(x, pass, fun, B)); list(lo = b[1], hi = b[2]) }

# --- data ----------------------------------------------------------------------------------
tiles <- fread(file.path(AD, "tiles_upe.csv"))
tiles[, als_date := as.Date(als_date)]
tiles[, path := file.path(Sys.getenv("LAZ_DIR", file.path(ROOT, "data/raw/laz")), tile_file_name)]   # LAZ only needed for figure 12
dm <- function(d) paste(as.integer(format(d, "%d")), format(d, "%b"))
spr <- tiles[month(als_date) %in% 5:6, range(als_date)]; lat <- tiles[!month(als_date) %in% 5:6, range(als_date)]
S_SPRING <- sprintf("Spring %s (%s\u2013%s, leaf-out)", year(spr[1]), dm(spr[1]), dm(spr[2]))
S_LATE   <- sprintf("Late summer %s (%s\u2013%s, leaf-on)", year(lat[1]), dm(lat[1]), dm(lat[2]))
SEASON_PAL <- setNames(c("#c2479a", "#5b8c00"), c(S_SPRING, S_LATE))
tiles[, als_season := factor(ifelse(month(als_date) %in% 5:6, S_SPRING, S_LATE), levels = c(S_LATE, S_SPRING))]
tinfo <- tiles[, .(tile_file_name, als_date, als_season, CODE_EPSG, path)]
ws <- fread(file.path(AD, "als_tile_wall_to_wall.csv"))

plots <- fread(file.path(AD, "plots_upe.csv"))
plots <- merge(plots, tinfo[, .(tile_file_name, als_season)], by = "tile_file_name")
plots[, forest_type := factor(forest_type, levels = names(FT_PAL))]
pchk <- merge(fread(file.path(AD, "als_at_plots_check.csv")), plots[, intersect(c("plot_id", "zq95", "zq50", "canopy_cover_2m_fr"), names(plots)), with = FALSE], by = "plot_id")

sg <- fread(file.path(AD, "samples_gedi.csv"), colClasses = list(character = "time"))
ag <- fread(file.path(AD, "als_at_gedi.csv"), colClasses = list(character = "time"))[, tile_file_name := NULL]
G <- merge(sg, ag, by = c("time", "beam"))
G <- merge(G, tinfo[, .(tile_file_name, als_date, als_season)], by = "tile_file_name")
G[, `:=`(date = as.Date(substr(time, 1, 10)), h = pmax(rh98, 0), pass = paste(orbit, beam),
         night = solar_elevation < 0, power = beam %in% c(5, 6, 8, 11))]
G[, `:=`(year = year(date), month = month(date), gap = as.numeric(date - als_date) / 365.25)]
G <- G[als_n >= 100]

sa <- fread(file.path(AD, "samples_atl08.csv"), colClasses = list(character = "time_ns"))
aa <- fread(file.path(AD, "als_at_atl08.csv"), colClasses = list(character = "time_ns"))[, tile_file_name := NULL]
A <- merge(sa, aa, by = c("time_ns", "rgt", "cycle", "gt", "segment_id_beg"))
A <- merge(A, tinfo[, .(tile_file_name, als_date, als_season)], by = "tile_file_name")
A[, `:=`(date = as.Date(substr(time_ns, 1, 10)), h = fifelse(is.na(h_canopy), 0, h_canopy),
         h_als = fifelse(als_n_can < 3 | is.na(als_p98_can), 0, als_p98_can), strong = spot %in% c(1, 3, 5),
         night = solar_elevation < 0, pass = paste(rgt, gt, substr(time_ns, 1, 10)),
         ph_frac = n_ca_photons / (n_ca_photons + n_te_photons))]
A[, `:=`(year = year(date), month = month(date), gap = as.numeric(date - als_date) / 365.25)]
A <- A[als_n >= 300]

# disturbance status AT THE SATELLITE DATE: an MRNF event between the ALS year and the satellite year
dstat <- function(ev, yr_ev, yr_sat) factor(fifelse(ev == "none" | is.na(yr_ev) | yr_ev > yr_sat, "No event",
                                             fifelse(ev == "harvest (stand-replacing)", "Harvest (stand-replacing)",
                                                     fifelse(ev == "partial cut / tending", "Partial cut / tending", "Other"))),
                                             levels = c(names(DIST_PAL), "Other"))
G[, dist := dstat(post_als_event, post_als_year, year)]; A[, dist := dstat(post_als_event, post_als_year, year)]
G[, ft := factor(fifelse(near_plot_dist <= 250, near_forest_type, NA_character_), levels = names(FT_PAL))]
A[, ft := factor(fifelse(near_plot_dist <= 250, near_forest_type, NA_character_), levels = names(FT_PAL))]
G[, default := leaf_off_flag == 0 & sensitivity >= 0.95 & h <= 60]
A[, default := segment_snowcover == 1 & strong & h <= 60]
Gc <- G[default & dist == "No event"]; Ac <- A[default & dist == "No event"]       # the clean sets

say("ALS: %d plots in %d tiles; %s; %s", nrow(plots), nrow(tiles), S_LATE, S_SPRING)
say("Plots by forest type: %s", paste(names(table(plots$forest_type)), table(plots$forest_type), collapse = ", "))
say("Footprints with ALS: GEDI %s (default filters + no post-ALS event: %s, %d passes); ATL08 %s (%s, %d passes)",
    fmt(nrow(G)), fmt(nrow(Gc)), uniqueN(Gc$pass), fmt(nrow(A)), fmt(nrow(Ac)), uniqueN(Ac$pass))
say("Post-ALS MRNF events at the satellite date: GEDI %s; ATL08 %s",
    paste(names(table(G$dist)), table(G$dist), collapse = ", "), paste(names(table(A$dist)), table(A$dist), collapse = ", "))

# check: this ALS processing (provider ground, whole-tile TIN) vs data/plot_als_metrics.csv (CSF ground, 30 m clip)
ck <- stats_pair(pchk$als_rh95, pchk$zq95); ck2 <- stats_pair(pchk$als_cover2, pchk$canopy_cover_2m_fr)
say("Check vs the plot ALS table: P95 n=%d r=%.3f bias=%+.2f m RMSE=%.2f m; cover2 r=%.3f bias=%+.3f",
    ck$n, ck$r, ck$bias, ck$rmse, ck2$r, ck2$bias)

###############################################################################
# 11 Design: where the plots are and when each instrument looked
###############################################################################
cat("figure 11\n")
area <- st_read(file.path(ROOT, "data/study_area/upe1415_study_area.shp"), quiet = TRUE) |> st_transform(2950)
p11a <- ggplot() + geom_sf(data = area, fill = "grey97", colour = "grey40", linewidth = 0.35) +
  geom_point(data = plots, aes(x2950, y2950, colour = forest_type, shape = als_season), size = 1.5, stroke = 0.6) +
  scale_colour_manual(values = FT_PAL, name = "Forest type (field)", drop = FALSE) +
  scale_shape_manual(values = setNames(c(16, 2), c(S_LATE, S_SPRING)), name = "ALS flight") +
  coord_sf(crs = 2950, datum = 4326) + theme(axis.title = element_blank(), legend.position = "bottom",
                                             legend.box = "vertical", legend.margin = margin(0, 0, 0, 0)) +
  guides(colour = guide_legend(nrow = 2, override.aes = list(size = 2.5)), shape = guide_legend(nrow = 2)) +
  labs(title = sprintf("%d PEP plots with ALS", nrow(plots)),
       subtitle = "Each plot sits in a 1 km ALS tile; satellite samples\ninside those tiles are compared with the ALS")
mon <- function(d, what) d[, .N, by = .(m = as.Date(format(date, "%Y-%m-15")))][, what := what][]
tl <- rbind(mon(tiles[, .(date = als_date)], "ALS flights (tiles)"),
            plots[, .N, by = .(m = as.Date(sprintf("%d-07-01", field_year)))][, what := "Field remeasurement (plots)"],
            mon(Ac, "ICESat-2 ATL08 (segments)"), mon(Gc, "GEDI L2A (footprints)"))
tl[, what := factor(what, levels = rev(c("ALS flights (tiles)", "Field remeasurement (plots)",
                                         "ICESat-2 ATL08 (segments)", "GEDI L2A (footprints)")))]
tl <- tl[m >= as.Date("2016-06-01")]
TLCOL <- c("ALS flights (tiles)" = "#333333", "Field remeasurement (plots)" = "#777777",
           "ICESat-2 ATL08 (segments)" = SENSOR[[1]], "GEDI L2A (footprints)" = SENSOR[[2]])
p11b <- ggplot(tl, aes(m, what)) + geom_blank() +
  annotate("rect", xmin = as.Date("2023-03-17"), xmax = as.Date("2024-04-20"), ymin = 0.5, ymax = 1.5, fill = "grey90") +
  annotate("text", x = as.Date("2023-10-01"), y = 1.38, label = "GEDI stored\non the ISS", size = 2.4, colour = INK2, lineheight = 0.9) +
  geom_point(aes(size = N, colour = what), alpha = 0.85) +
  scale_size_area(max_size = 7, name = "Count per month\n(field: per year)", breaks = c(10, 100, 1000)) +
  scale_colour_manual(values = TLCOL, guide = "none") +
  scale_x_date(date_breaks = "1 year", date_labels = "%Y", limits = as.Date(c("2017-01-01", "2025-12-31"))) +
  labs(x = NULL, y = NULL, title = "When each instrument looked",
       subtitle = sprintf("Satellites: June\u2013September, default filters, no harvest after the ALS. The gap between ALS and satellite\nis 1\u20138 years (median %.1f years for GEDI, %.1f for ICESat-2).",
                          median(Gc$gap), median(Ac$gap))) +
  theme(legend.position = "bottom", panel.grid.major.y = element_blank())
p11 <- (p11a | p11b) + plot_layout(widths = c(1, 1.5)) +
  plot_annotation(title = "Comparing the satellites with airborne lidar at the inventory plots",
                  subtitle = "UPE 14\u201315: ALS from the Quebec provincial program (Optech Galaxy, 2.5 pts/m\u00b2 nominal, ~14 measured), PEP permanent plots (11.28 m radius)",
                  theme = theme(plot.title = element_text(face = "bold", size = 13)))
save(p11, "11_als_design_map_timeline.png", 12.5, 6)

###############################################################################
# 12 Same ground, three instruments: one tile, one GEDI footprint, one ATL08 segment
###############################################################################
cat("figure 12 (reads one LAZ tile)\n")
score <- merge(Gc[, .(ng = .N), by = tile_file_name], Ac[, .(na = .N), by = tile_file_name], by = "tile_file_name")
ex_tile <- score[order(-(pmin(na, 20) * 5 + ng))]$tile_file_name[1]
tt <- tiles[tile_file_name == ex_tile]
chm_file <- file.path(CHMD, sub("\\.LAZ$", "_chm_dm.tif", ex_tile))
if (!file.exists(tt$path) || !file.exists(chm_file)) {
  cat("  figure 12 skipped: it needs the LAZ tile", ex_tile, "in", dirname(tt$path), "and its CHM from step 10\n")
} else {
  chm <- rast(chm_file) / 10
  chm2 <- aggregate(chm, 2, max, na.rm = TRUE); cd <- as.data.frame(chm2, xy = TRUE); names(cd)[3] <- "z"
  ge <- Gc[tile_file_name == ex_tile]; ae <- Ac[tile_file_name == ex_tile]
  pe <- plots[tile_file_name == ex_tile]
  pexy <- st_coordinates(st_transform(st_as_sf(pe, coords = c("longitude", "latitude"), crs = 4326), tt$CODE_EPSG))
  rect_sf <- function(d, L = 50, W = 7) st_sfc(lapply(seq_len(nrow(d)), function(i) {
    cx <- d$x_tile[i]; cy <- d$y_tile[i]; ux <- d$ux[i]; uy <- d$uy[i]
    m <- rbind(c(cx - L * ux - W * uy, cy - L * uy + W * ux), c(cx + L * ux - W * uy, cy + L * uy + W * ux),
               c(cx + L * ux + W * uy, cy + L * uy - W * ux), c(cx - L * ux + W * uy, cy - L * uy - W * ux))
    st_polygon(list(rbind(m, m[1, ])))
  }), crs = tt$CODE_EPSG)
  # typical examples: the footprint / segment whose error is closest to the tile's median absolute error
  pick_typ <- function(e) { i <- which.min(abs(abs(e) - median(abs(e)))); i }
  gi <- ge[pick_typ(ge$rh98 - ge$als_rh98)]; ai <- ae[h_als > 5][pick_typ(ae[h_als > 5]$h - ae[h_als > 5]$h_als)]
  las <- readLAS(tt$path, select = "xyzrnc", filter = "-drop_withheld -drop_class 7 18")
  las <- normalize_height(las, tin(), use_class = 2L); las <- filter_poi(las, Z >= -2, Z <= 60); las$Z[las$Z < 0] <- 0
  lg <- clip_circle(las, gi$x_tile, gi$y_tile, 12.5)
  la <- clip_roi(las, rect_sf(ai)); if (is.list(la) && !inherits(la, "LAS")) la <- la[[1]]
  rm(las); invisible(gc())
  p12a <- ggplot() + geom_raster(data = cd, aes(x, y, fill = z)) +
    scale_fill_gradientn(colours = H_PAL, limits = c(0, 30), oob = squish, name = "ALS canopy\nheight (m)") +
    geom_sf(data = st_buffer(st_as_sf(ge, coords = c("x_tile", "y_tile"), crs = tt$CODE_EPSG), 12.5), fill = NA,
            colour = SENSOR[[2]], linewidth = 0.45) +
    geom_sf(data = rect_sf(ae), fill = NA, colour = SENSOR[[1]], linewidth = 0.45) +
    geom_sf(data = st_buffer(st_as_sf(data.frame(x = pexy[, 1], y = pexy[, 2]), coords = c("x", "y"), crs = tt$CODE_EPSG), 11.28),
            fill = NA, colour = "black", linewidth = 0.8) +
    geom_sf(data = st_buffer(st_as_sf(gi, coords = c("x_tile", "y_tile"), crs = tt$CODE_EPSG), 25), fill = NA, colour = "black", linewidth = 0.3, linetype = "22") +
    geom_sf(data = st_buffer(st_centroid(rect_sf(ai)), 60), fill = NA, colour = "black", linewidth = 0.3, linetype = "22") +
    ggspatial::annotation_scale(location = "bl", width_hint = 0.25, text_cex = 0.7) +
    coord_sf(crs = tt$CODE_EPSG, datum = NA, expand = FALSE) + theme_void() +
    theme(plot.title = element_text(face = "bold", size = 11), plot.subtitle = element_text(colour = INK2, size = 8.5)) +
    labs(title = sprintf("One ALS tile (1 km\u00b2, flown %s %d)", dm(tt$als_date), year(tt$als_date)),
         subtitle = sprintf("Orange circles: %d GEDI footprints. Blue rectangles: %d ICESat-2 segments.\nBlack circle: PEP plot. Dashed: the two samples on the right.", nrow(ge), nrow(ae)))
  side <- function(l, cx, cy, ux = 1, uy = 0, off = 0) data.table(s = (l$X - cx) * ux + (l$Y - cy) * uy + off, z = l$Z, g = l$Classification == 2L)
  sg1 <- side(lg, gi$x_tile, gi$y_tile)
  hl <- function(v, lab, col, lt) data.table(v = v, lab = lab, col = col, lt = lt)
  lines_g <- rbind(hl(gi$rh98, "GEDI RH98", SENSOR[[2]], "solid"), hl(gi$rh50, "GEDI RH50", SENSOR[[2]], "22"),
                   hl(gi$als_rh98, "ALS P98", "black", "solid"), hl(gi$als_rh50, "ALS P50", "black", "22"))
  prof_panel <- function(pts, ln, title, sub, xl) {
    ggplot(pts, aes(s, z)) + geom_point(aes(colour = g), size = 0.25, alpha = 0.6, shape = 16) +
      scale_colour_manual(values = c(`TRUE` = "#8a6d3b", `FALSE` = "#5f9e5a"), labels = c(`TRUE` = "ground", `FALSE` = "other"), name = "ALS return") +
      geom_hline(data = ln, aes(yintercept = v, linetype = lt), colour = ln$col, linewidth = 0.6) +
      scale_linetype_identity() +
      geom_text(data = ln[!grepl("^ALS", lab)], aes(x = min(pts$s), y = v, label = sprintf("%s %.1f m", lab, v)),
                colour = "grey15", hjust = 0, vjust = -0.3, size = 2.5) +
      geom_text(data = ln[grepl("^ALS", lab)], aes(x = max(pts$s), y = v, label = sprintf("%s %.1f m", lab, v)),
                colour = "grey15", hjust = 1, vjust = 1.3, size = 2.5) +
      labs(x = xl, y = "Height above ground (m)", title = title, subtitle = sub) +
      theme(legend.position = "none", plot.title = element_text(size = 10), plot.subtitle = element_text(size = 8))
  }
  p12b <- prof_panel(sg1, lines_g, "A GEDI footprint, seen from the side",
                     sprintf("%s ALS returns within 12.5 m; shot %s, %s", fmt(nrow(sg1)), format(gi$date, "%d %b %Y"), ifelse(gi$night, "night", "day")),
                     "West\u2013east position in the footprint (m)")
  sa1 <- side(la, ai$x_tile, ai$y_tile, ai$ux, ai$uy, 50)
  lines_a <- rbind(hl(ai$h, "ATL08 h_canopy", SENSOR[[1]], "solid"), hl(ai$ch_p50, "ATL08 canopy P50", SENSOR[[1]], "22"),
                   hl(ai$h_als, "ALS P98 > 0.5 m", "black", "solid"), hl(ai$als_p50_can, "ALS P50 > 0.5 m", "black", "22"))
  p12c <- prof_panel(sa1, lines_a, "An ICESat-2 segment, seen from the side",
                     sprintf("%s ALS returns in the 100 \u00d7 14 m segment; %s beam, %s, %s", fmt(nrow(sa1)), ifelse(ai$strong, "strong", "weak"),
                             format(ai$date, "%d %b %Y"), ifelse(ai$night, "night", "day")), "Distance along the track (m)")
  pcs <- seq(0, 100, 1)
  cg <- rbind(data.table(p = c(10, 25, 50, 75, 90, 95, 98, 100), h = unlist(gi[, .(rh10, rh25, rh50, rh75, rh90, rh95, rh98, rh100)]), src = "GEDI RH"),
              data.table(p = pcs, h = quantile(lg$Z, pcs / 100, names = FALSE), src = "ALS, all returns"))
  ca <- rbind(data.table(p = c(seq(10, 95, 5), 98), h = c(unlist(ai[, paste0("ch_p", seq(10, 95, 5)), with = FALSE]), ai$h), src = "ATL08 canopy percentiles"),
              data.table(p = pcs, h = quantile(la$Z[la$Z > 0.5], pcs / 100, names = FALSE), src = "ALS, returns > 0.5 m"))
  curve_panel <- function(d, col, title) {
    ggplot(d, aes(h, p)) + geom_line(data = d[!grepl("^ALS", src)], colour = col, linewidth = 0.7) +
      geom_point(data = d[!grepl("^ALS", src)], colour = col, size = 1.6) +
      geom_line(data = d[grepl("^ALS", src)], colour = "black", linewidth = 0.6) +
      labs(x = "Height (m)", y = "Percentile", title = title) + theme(plot.title = element_text(size = 10))
  }
  p12d <- curve_panel(cg, SENSOR[[2]], "Same footprint: RH curve") +
    annotate("text", x = Inf, y = 8, hjust = 1.05, size = 2.5, colour = "grey15", label = "dots: GEDI   black: ALS (all returns)")
  p12e <- curve_panel(ca, SENSOR[[1]], "Same segment: canopy percentiles") +
    annotate("text", x = Inf, y = 8, hjust = 1.05, size = 2.5, colour = "grey15", label = "dots: ATL08   black: ALS (> 0.5 m)")
  p12 <- (p12a | ((p12b | p12d) + plot_layout(widths = c(1.6, 1))) / ((p12c | p12e) + plot_layout(widths = c(1.6, 1)))) +
    plot_layout(widths = c(1, 1.45)) +
    plot_annotation(title = "The same ground seen by ALS, GEDI and ICESat-2",
                    subtitle = "GEDI RH metrics are percentiles of returned energy from the ground up, so their ALS counterpart is the percentile of ALL returns.\nATL08 canopy metrics are percentiles of canopy photons only (from about 0.5 m above the ground), so their ALS counterpart is the percentile of returns above 0.5 m.",
                    theme = theme(plot.title = element_text(face = "bold", size = 13)))
  save(p12, "12_same_ground_three_instruments.png", 14, 7.6)
}

###############################################################################
# 13 Footprint-level agreement
###############################################################################
cat("figure 13\n")
pairs <- list(
  list(G = Gc, s = "rh98", a = "als_rh98", sen = "GEDI L2A", lab = "Top height: GEDI RH98 vs ALS P98 (all returns)"),
  list(G = Gc, s = "rh75", a = "als_rh75", sen = "GEDI L2A", lab = "GEDI RH75 vs ALS P75 (all returns)"),
  list(G = Gc, s = "rh50", a = "als_rh50", sen = "GEDI L2A", lab = "GEDI RH50 vs ALS P50 (all returns)"),
  list(G = Ac, s = "h", a = "h_als", sen = "ICESat-2 ATL08", lab = "Top height: ATL08 h_canopy vs ALS P98 (returns > 0.5 m)"),
  list(G = Ac[h > 2 & h_als > 2], s = "ch_p75", a = "als_p75_can", sen = "ICESat-2 ATL08", lab = "ATL08 canopy P75 vs ALS P75 (returns > 0.5 m)"),
  list(G = Ac[h > 2 & h_als > 2], s = "ch_p50", a = "als_p50_can", sen = "ICESat-2 ATL08", lab = "ATL08 canopy P50 vs ALS P50 (returns > 0.5 m)"))
agree <- rbindlist(lapply(pairs, function(p) cbind(sensor = p$sen, metric = p$s, stats_pair(p$G[[p$s]], p$G[[p$a]]))))
alt <- Ac[h > 2 & h_als > 2]
agree <- rbind(agree, cbind(sensor = "ICESat-2 ATL08", metric = c("h (ALS > 2 m)", "ch_p50 (ALS > 2 m)"),
                            rbind(stats_pair(Ac$h, fifelse(Ac$als_n_can2 < 3 | is.na(Ac$als_p98_can2), 0, Ac$als_p98_can2)),
                                  stats_pair(alt$ch_p50, alt$als_p50_can2))))
fwrite(agree, file.path(OUTC, "footprint_agreement.csv"))
for (i in seq_len(nrow(agree))) with(agree[i], say("Footprint %s %s: n=%d r=%.2f bias=%+.2f RMSE=%.2f MAE=%.2f within3m=%.0f%%",
                                                    sensor, metric, n, r, bias, rmse, mae, 100 * within3))
scat <- function(p) {
  d <- data.table(s = p$G[[p$s]], a = p$G[[p$a]]); st <- stats_pair(d$s, d$a)
  lim <- c(min(0, quantile(c(d$s, d$a), 0.001, na.rm = TRUE)), quantile(c(d$s, d$a), 0.999, na.rm = TRUE))
  ggplot(d, aes(a, s)) + geom_bin2d(binwidth = c(0.75, 0.75)) +
    scale_fill_gradient(low = "#eeeeee", high = SENSOR[[p$sen]], trans = "log10", name = "Samples") +
    geom_abline(slope = 1, intercept = 0, linewidth = 0.4, colour = "black") +
    annotate("label", x = lim[1], y = lim[2], label = stat_lab(st), hjust = 0, vjust = 1, size = 2.6,
             fill = alpha("white", 0.85), border.colour = NA, colour = "grey15") +
    coord_fixed(xlim = lim, ylim = lim) + labs(x = "ALS on the same ground (m)", y = paste(p$sen, "(m)"), subtitle = p$lab) +
    theme(plot.subtitle = element_text(size = 8.5, colour = "grey15"), legend.key.width = unit(0.3, "cm"))
}
p13 <- wrap_plots(lapply(pairs, scat), ncol = 3) +
  plot_annotation(title = "Footprint by footprint: how close each satellite metric is to its ALS counterpart",
                  subtitle = sprintf("Default filters, June\u2013September 2019\u20132025, footprints without a harvest or partial cut after the ALS flight. Line = 1:1. ATL08 P75/P50 only where both\nsee canopy taller than 2 m. GEDI: %s footprints, %d passes; ICESat-2: %s segments, %d passes.",
                                     fmt(nrow(Gc)), uniqueN(Gc$pass), fmt(nrow(Ac)), uniqueN(Ac$pass)),
                  theme = theme(plot.title = element_text(face = "bold", size = 13)))
save(p13, "13_footprint_agreement.png", 13, 8.6)

###############################################################################
# 14 By forest type and ALS season
###############################################################################
cat("figure 14\n")
strat <- function(d, sen, s, a, metric, tall = FALSE) {
  d <- d[!is.na(ft) & is.finite(get(s)) & is.finite(get(a))]
  d[, dd := if (tall) 100 * ((get(s) >= 5) - (get(a) >= 5)) else get(s) - get(a)]
  d[, { b <- ci(dd, pass); .(est = mean(dd), lo = b$lo, hi = b$hi, n = .N, np = uniqueN(pass)) }, by = .(ft, als_season)][
    , `:=`(sensor = sen, metric = metric)][]
}
M1 <- "Top height difference (m)"; M2 <- "Median height difference (m)"; M3 <- "Share of samples \u2265 5 m,\ndifference (% points)"
S14 <- rbind(strat(Gc, "GEDI L2A", "rh98", "als_rh98", M1), strat(Ac, "ICESat-2 ATL08", "h", "h_als", M1),
             strat(Gc, "GEDI L2A", "rh50", "als_rh50", M2), strat(Ac[h > 2 & h_als > 2], "ICESat-2 ATL08", "ch_p50", "als_p50_can", M2),
             strat(Gc, "GEDI L2A", "rh98", "als_rh98", M3, TRUE), strat(Ac, "ICESat-2 ATL08", "h", "h_als", M3, TRUE))
S14[, metric := factor(metric, levels = c(M1, M2, M3))]; S14[, sensor := factor(sensor, levels = SENS_LEV)]
fwrite(S14, file.path(OUTC, "difference_by_forest_type_and_season.csv"))
p14 <- ggplot(S14[n >= 15], aes(ft, est, colour = als_season, group = als_season)) +
  geom_hline(yintercept = 0, colour = "grey50", linewidth = 0.3) +
  geom_errorbar(aes(ymin = lo, ymax = hi), width = 0, linewidth = 0.6, position = position_dodge(0.5)) +
  geom_point(size = 2.2, position = position_dodge(0.5)) +
  geom_text(aes(y = hi, label = n), position = position_dodge(0.5), vjust = -0.5, size = 2.2, colour = INK2, show.legend = FALSE) +
  scale_colour_manual(values = SEASON_PAL, name = "ALS flight") +
  facet_grid(metric ~ sensor, scales = "free_y", switch = "y") +
  scale_y_continuous(expand = expansion(mult = c(0.08, 0.18))) +
  labs(x = "Forest type of the nearest PEP plot (within 250 m)", y = NULL,
       title = "Satellite minus ALS, by forest type and by when the ALS was flown",
       subtitle = "Mean difference with 95% interval (bootstrap over passes); numbers = footprints. Positive = the satellite sees more or taller canopy than the ALS.\nSame filters and exclusions as figure 13; strata with fewer than 15 footprints are not shown.") +
  theme(legend.position = "bottom", strip.placement = "outside", strip.text.y.left = element_text(angle = 90),
        panel.border = element_rect(fill = NA, colour = "grey85"))
save(p14, "14_difference_by_forest_type_and_season.png", 11, 9)

###############################################################################
# 15 Period: years between ALS and satellite, and disturbances in between
###############################################################################
cat("figure 15\n")
per <- function(d, sen, s, a) {
  d <- d[default & dist %in% names(DIST_PAL) & is.finite(get(s)) & is.finite(get(a))]
  d[, dd := get(s) - get(a)][, gbin := floor(gap) + 0.5]
  out <- d[, { b <- ci(dd, pass, median); .(est = median(dd), lo = b$lo, hi = b$hi, n = .N) }, by = .(gbin, dist)]
  fit <- coef(lm(dd ~ gap, data = d[dist == "No event" & abs(dd) < 15]))
  list(tab = out[, sensor := sen][], slope = fit[2], d = d[, .(dd, dist, sensor = sen)])
}
P1 <- per(G, "GEDI L2A", "rh98", "als_rh98"); P2 <- per(A, "ICESat-2 ATL08", "h", "h_als")
say("Undisturbed drift of top-height difference: GEDI %+.2f m/yr, ATL08 %+.2f m/yr", P1$slope, P2$slope)
for (P in list(P1, P2)) for (k in names(DIST_PAL)) {
  x <- P$d[dist == k]$dd; if (length(x)) say("  %s %s: n=%d median diff=%+.1f m, share < -5 m = %.0f%%", P$d$sensor[1], k, length(x), median(x), 100 * mean(x < -5))
}
T15 <- rbind(P1$tab, P2$tab)[n >= 10]; T15[, sensor := factor(sensor, levels = SENS_LEV)]
p15a <- ggplot(T15, aes(gbin, est, colour = dist)) + geom_hline(yintercept = 0, colour = "grey50", linewidth = 0.3) +
  geom_errorbar(aes(ymin = lo, ymax = hi), width = 0, linewidth = 0.5, position = position_dodge(0.3)) +
  geom_line(position = position_dodge(0.3), linewidth = 0.4) + geom_point(position = position_dodge(0.3), size = 1.8) +
  scale_colour_manual(values = DIST_PAL, name = "MRNF record between the ALS\nflight and the satellite date", drop = FALSE, limits = names(DIST_PAL)) +
  facet_wrap(~sensor) + scale_x_continuous(breaks = 1:8) +
  labs(x = "Years between the ALS flight and the satellite sample", y = "Median top-height difference,\nsatellite \u2212 ALS (m)",
       title = "a  The longer the gap, the more the forest has changed",
       subtitle = sprintf("Undisturbed footprints drift by %+.2f m/yr (GEDI) and %+.2f m/yr (ICESat-2): growth after the flight. Harvested ones drop.\nMedian with 95%% interval (bootstrap over passes); bins with fewer than 10 samples hidden.", P1$slope, P2$slope)) +
  theme(legend.position = "right", panel.border = element_rect(fill = NA, colour = "grey85"))
D15 <- rbind(P1$d, P2$d); D15[, sensor := factor(sensor, levels = SENS_LEV)]
p15b <- ggplot(D15[abs(dd) <= 25], aes(dd, after_stat(density), colour = dist)) +
  geom_density(bw = 1, linewidth = 0.6, fill = NA) + geom_vline(xintercept = 0, colour = "grey50", linewidth = 0.3) +
  scale_colour_manual(values = DIST_PAL, guide = "none", drop = FALSE) + facet_wrap(~sensor) +
  labs(x = "Top-height difference, satellite \u2212 ALS (m)", y = "Density",
       title = "b  A harvest after the flight shows up as a long negative tail",
       subtitle = "All years; default filters. These footprints are excluded from figures 13, 14 and 16.") +
  theme(panel.border = element_rect(fill = NA, colour = "grey85"))
p15 <- (p15a / p15b) + plot_annotation(title = "Periods matter: the forest keeps changing after the ALS flight",
                                        theme = theme(plot.title = element_text(face = "bold", size = 13)))
save(p15, "15_period_gap_and_disturbance.png", 11.5, 8.6)

###############################################################################
# 16 Were the filters right? Each filter checked against ALS
###############################################################################
cat("figure 16\n")
G0 <- G[dist == "No event" & h <= 60]; A0 <- A[dist == "No event" & h <= 60 & segment_snowcover == 1]
# one call = one filter; lab_t / lab_f name the two groups; filtered = FALSE for splits the guide does not filter on
cmp <- function(d, keep, lab_t, lab_f, sen, s, a, filtered = TRUE) {
  d <- d[!is.na(keep)]; d[, kp := keep]
  d[, `:=`(dd = get(s) - get(a), miss = get(a) >= 5 & get(s) < 2)]
  d[, { b1 <- ci(dd, pass); b2 <- ci(abs(dd), pass); b3 <- ci(as.numeric(miss[get(a) >= 5]), pass[get(a) >= 5])
    .(bias = mean(dd), bias_lo = b1$lo, bias_hi = b1$hi, mae = mean(abs(dd)), mae_lo = b2$lo, mae_hi = b2$hi,
      miss = 100 * mean(miss[get(a) >= 5]), miss_lo = 100 * b3$lo, miss_hi = 100 * b3$hi, n = .N) }, by = kp][
    , `:=`(sensor = sen, test = paste(lab_t, "/", lab_f), row = fifelse(kp, lab_t, lab_f),
           group = if (filtered) fifelse(kp, "Kept by default", "Dropped by default") else "Not a default filter")][
    order(-kp)][]
}
gs_ <- G0[leaf_off_flag == 0]
F16 <- rbind(
  cmp(G0[sensitivity >= 0.95], G0[sensitivity >= 0.95]$leaf_off_flag == 0, "Leaf-off flag = 0", "Leaf-off flag = 1", "GEDI L2A", "rh98", "als_rh98"),
  cmp(gs_, gs_$sensitivity >= 0.95, "Sensitivity \u2265 0.95", "Sensitivity 0.90\u20130.95", "GEDI L2A", "rh98", "als_rh98"),
  cmp(Gc, Gc$power, "Power beams", "Coverage beams", "GEDI L2A", "rh98", "als_rh98", FALSE),
  cmp(Gc, Gc$night, "Night shots", "Day shots", "GEDI L2A", "rh98", "als_rh98", FALSE),
  cmp(A0, A0$strong, "Strong beams", "Weak beams", "ICESat-2 ATL08", "h", "h_als"),
  cmp(A0[strong == TRUE], A0[strong == TRUE]$night, "Night passes", "Day passes", "ICESat-2 ATL08", "h", "h_als", FALSE))
fwrite(F16, file.path(OUTC, "filters_checked_against_als.csv"))
for (i in seq_len(nrow(F16))) with(F16[i], say("Filter %s | %s | %s: n=%d bias=%+.2f MAE=%.2f miss=%.1f%%", sensor, row, group, n, bias, mae, miss))
F16[, lab := sprintf("%s (n = %s)", row, fmt(n))]; F16[, lab := factor(lab, levels = rev(unique(lab)))]
F16[, sensor := factor(sensor, levels = SENS_LEV)]
GRP_PAL <- c(KEEP_PAL, "Not a default filter" = "#7d55d0")
fl <- melt(F16, id.vars = c("lab", "group", "n", "sensor"), measure.vars = list(c("bias", "mae", "miss"), c("bias_lo", "mae_lo", "miss_lo"), c("bias_hi", "mae_hi", "miss_hi")),
           value.name = c("est", "lo", "hi"))
fl[, variable := factor(c("Mean difference (m)", "Mean absolute difference (m)", "Canopy missed (%):\nsatellite < 2 m where ALS \u2265 5 m")[variable],
                        levels = c("Mean difference (m)", "Mean absolute difference (m)", "Canopy missed (%):\nsatellite < 2 m where ALS \u2265 5 m"))]
p16 <- ggplot(fl, aes(est, lab, colour = group)) + geom_vline(data = data.frame(variable = factor(levels(fl$variable)[1], levels = levels(fl$variable)), x = 0), aes(xintercept = x), colour = "grey50", linewidth = 0.3) +
  geom_errorbar(aes(xmin = lo, xmax = hi), width = 0, orientation = "y", linewidth = 0.6) +
  geom_point(size = 2.1) +
  scale_colour_manual(values = GRP_PAL, name = NULL, breaks = names(GRP_PAL)) +
  facet_grid(sensor ~ variable, scales = "free", space = "free_y") +
  labs(x = NULL, y = NULL, title = "Each quality filter checked against ALS on the same ground",
       subtitle = "Top height (GEDI RH98, ATL08 h_canopy) against ALS P98, footprints without a post-ALS harvest. Rows come in pairs: only that filter changes,\nthe others stay at their default. 95% intervals: bootstrap over passes. GEDI shots arrive with the server-side quality filters already applied.") +
  theme(legend.position = "bottom", panel.border = element_rect(fill = NA, colour = "grey85"), panel.grid.major.y = element_blank(),
        strip.text.y = element_text(angle = 0, hjust = 0))
save(p16, "16_filters_checked_against_als.png", 13, 6.2)

###############################################################################
# 17 Plot level: the plot's ALS metrics against the satellite samples around it
###############################################################################
cat("figure 17\n")
near <- function(S, v_sat, v_als, r) rbindlist(lapply(seq_len(nrow(plots)), function(i) {
  dx <- S$x2950 - plots$x2950[i]; dy <- S$y2950 - plots$y2950[i]; k <- which(dx * dx + dy * dy <= r * r)
  if (!length(k)) return(NULL)
  data.table(plot_id = plots$plot_id[i], radius = r, n_samples = length(k), sat = median(S[[v_sat]][k]), als = median(S[[v_als]][k]))
}))
P0 <- plots[post_als_event == "none"]
RADII <- c(25, 50, 100, 250, 500)
NB <- rbind(rbindlist(lapply(RADII, function(r) near(Gc, "rh95", "als_rh95", r)))[, sensor := "GEDI L2A"],
            rbindlist(lapply(RADII[-1], function(r) near(Ac, "h", "h_als", r)))[, sensor := "ICESat-2 ATL08"])
NB <- merge(NB, P0[, .(plot_id, zq95, forest_type)], by = "plot_id")
RR <- NB[, rbind(cbind(src = "Satellite", stats_pair(sat, zq95)), cbind(src = "ALS at the same footprints", stats_pair(als, zq95))), by = .(sensor, radius)]
fwrite(RR, file.path(OUTC, "plot_vs_neighbourhood_by_radius.csv"))
for (i in seq_len(nrow(RR))) with(RR[i], say("Plot P95 vs %s within %d m (%s): plots=%d r=%.2f bias=%+.2f RMSE=%.2f", sensor, as.integer(radius), src, n, r, bias, rmse))
RR[, sensor := factor(sensor, levels = SENS_LEV)]
p17a <- ggplot(RR, aes(radius, rmse, colour = sensor, linetype = src)) + geom_line(linewidth = 0.7) + geom_point(size = 1.8) +
  geom_text(data = RR[src == "Satellite"], aes(label = n), vjust = -0.9, size = 2.3, colour = INK2, show.legend = FALSE) +
  scale_colour_manual(values = SENSOR, name = NULL) +
  scale_linetype_manual(values = c("Satellite" = "solid", "ALS at the same footprints" = "22"), name = NULL) +
  scale_x_log10(breaks = RADII) + expand_limits(y = 0) +
  labs(x = "Search radius around the plot centre (m, log scale)", y = "RMSE against the plot's ALS P95 (m)",
       title = "a  Error against the plot, by search radius",
       subtitle = "Median of the samples within the radius. Numbers = plots with at least\none sample. Dashed = ALS at the same footprints: the part of the error\nthat comes from sampling different ground, not from the satellite.") +
  theme(legend.position = "bottom", legend.box = "vertical", legend.margin = margin(0, 0, 0, 0))
sc17 <- function(d, sen, r, xlab, legend = TRUE) {
  st <- stats_pair(d$sat, d$zq95); lim <- c(0, max(c(d$sat, d$zq95), na.rm = TRUE))
  ggplot(d, aes(zq95, sat, colour = forest_type)) + geom_abline(slope = 1, intercept = 0, linewidth = 0.3) +
    geom_point(size = 1.4, alpha = 0.85) + scale_colour_manual(values = FT_PAL, name = "Forest type", drop = FALSE, guide = if (legend) "legend" else "none") +
    annotate("label", x = 0, y = lim[2], label = stat_lab(st), hjust = 0, vjust = 1, size = 2.5, fill = alpha("white", 0.85), border.colour = NA, colour = "grey15") +
    coord_fixed(xlim = lim, ylim = lim) +
    labs(x = "Plot ALS P95, 400 m\u00b2 (m)", y = xlab, title = sprintf("%s  %s within %d m", ifelse(sen == "GEDI L2A", "b", "c"), sen, r))
}
p17b <- sc17(NB[sensor == "GEDI L2A" & radius == 100], "GEDI L2A", 100, "Median GEDI RH95 (m)")
p17c <- sc17(NB[sensor == "ICESat-2 ATL08" & radius == 250], "ICESat-2 ATL08", 250, "Median ATL08 h_canopy (m)", legend = FALSE)
FP <- plots[!is.na(field_htop) & field_n_heights >= 3]
FP[, changed := post_als_event != "none" & post_als_year <= field_year]
stf <- stats_pair(FP[!(changed)]$zq95, FP[!(changed)]$field_htop)
say("Plot ALS P95 vs field top height (mean of 3 tallest measured trees): n=%d r=%.2f bias(ALS-field)=%+.2f RMSE=%.2f", stf$n, stf$r, stf$bias, stf$rmse)
p17d <- ggplot(FP, aes(field_htop, zq95, colour = forest_type, shape = changed)) + geom_abline(slope = 1, intercept = 0, linewidth = 0.3) +
  geom_point(size = 1.4, alpha = 0.85) + scale_colour_manual(values = FT_PAL, guide = "none", drop = FALSE) +
  scale_shape_manual(values = c(`FALSE` = 16, `TRUE` = 4), labels = c(`FALSE` = "no event", `TRUE` = "cut between ALS and field"), name = NULL) +
  annotate("label", x = 0, y = 30, label = sprintf("%s\n(ALS \u2212 field)", stat_lab(stf)), hjust = 0, vjust = 1, size = 2.5, fill = alpha("white", 0.85), border.colour = NA, colour = "grey15") +
  coord_fixed(xlim = c(0, 30), ylim = c(0, 30)) + theme(legend.position = "bottom") +
  labs(x = "Field top height (m):\nmean of the 3 tallest measured trees", y = "Plot ALS P95 (m)", title = "d  And the ALS against the field")
p17 <- (p17a | p17b | p17c | p17d) + plot_layout(widths = c(1.15, 1, 1, 1), guides = "collect") &
  theme(legend.position = "bottom", legend.box = "horizontal")
p17 <- p17 +
  plot_annotation(title = "At the plot: what you get when you take the satellite samples around an inventory plot",
                  subtitle = sprintf("%d plots without a harvest after the ALS. Plot metric: P95 of all ALS returns in the 11.28 m plot (data/plot_als_metrics.csv). Field heights: 2019\u20132021 remeasurement.", nrow(P0)),
                  theme = theme(plot.title = element_text(face = "bold", size = 13)))
save(p17, "17_plot_level_comparison.png", 17, 5.8)

###############################################################################
# 18 Polygon metrics of the guide on 1 km2 tiles, against ALS
###############################################################################
cat("figure 18\n")
tilem <- function(d, sen, s, a, cov_a, min_n) {
  d[, .(n = .N, np = uniqueN(pass), sat_tall = mean(get(s) >= 5), als_tall = mean(get(a) >= 5),
        sat_hmed = median(get(s)[get(s) >= 2]), als_hmed = median(get(a)[get(a) >= 2]), als_fr5 = mean(get(cov_a), na.rm = TRUE)),
    by = tile_file_name][n >= min_n][, sensor := sen][]
}
TM <- rbind(tilem(Gc, "GEDI L2A", "h", "als_rh98", "als_cover5", 10), tilem(Ac, "ICESat-2 ATL08", "h", "h_als", "als_cover5", 5))
TM <- merge(TM, ws[, .(tile_file_name, chm_cover5, chm_med_can)], by = "tile_file_name")
TM[, sensor := factor(sensor, levels = SENS_LEV)]
fwrite(TM, file.path(OUTC, "tile_polygon_metrics_vs_als.csv"))
for (sn in names(SENSOR)) {
  x <- TM[sensor == sn]
  a1 <- stats_pair(x$sat_tall, x$als_tall); a2 <- stats_pair(x$sat_tall, x$chm_cover5); a3 <- stats_pair(x$als_fr5, x$chm_cover5)
  a4 <- stats_pair(x$sat_hmed, x$als_hmed)
  say("Tiles %s (n=%d, median %d samples): cover_tall sat vs ALS-same-footprints r=%.2f bias=%+.3f; sat vs CHM cover5 bias=%+.3f; ALS footprint first-return cover5 vs CHM bias=%+.3f; h_med sat vs ALS r=%.2f bias=%+.2f RMSE=%.2f",
      sn, nrow(x), as.integer(median(x$n)), a1$r, a1$bias, a2$bias, a3$bias, a4$r, a4$bias, a4$rmse)
}
TL <- melt(TM, id.vars = c("tile_file_name", "sensor", "chm_cover5"), measure.vars = c("sat_tall", "als_tall", "als_fr5"))
V_LAB <- c(gedi = "GEDI: share of footprints with RH98 \u2265 5 m (cover_tall)",
           atl = "ICESat-2: share of segments with h_canopy \u2265 5 m (cover_tall)",
           als_tall = "ALS, same samples: share with P98 \u2265 5 m",
           als_fr5 = "ALS, same samples: mean first-return cover > 5 m")
TL[, key := fifelse(variable == "sat_tall", fifelse(sensor == "GEDI L2A", "gedi", "atl"), as.character(variable))]
TL[, key := factor(V_LAB[key], levels = V_LAB)]
V_PAL <- setNames(c(SENSOR[["GEDI L2A"]], SENSOR[["ICESat-2 ATL08"]], "#333333", "#7d55d0"), V_LAB)
V_SHP <- setNames(c(16, 16, 1, 17), V_LAB)
p18a <- ggplot(TL, aes(chm_cover5, value, colour = key, shape = key)) + geom_abline(slope = 1, intercept = 0, linewidth = 0.3) +
  geom_point(size = 1.5, alpha = 0.85, stroke = 0.6) + facet_wrap(~sensor) +
  scale_colour_manual(values = V_PAL, name = NULL) + scale_shape_manual(values = V_SHP, name = NULL) +
  scale_x_continuous(labels = percent) + scale_y_continuous(labels = percent) + coord_fixed(xlim = c(0, 1), ylim = c(0, 1)) +
  guides(colour = guide_legend(ncol = 1, override.aes = list(size = 2.5))) +
  labs(x = "Wall-to-wall ALS canopy cover > 5 m (share of 1 m cells in the tile)", y = "Polygon value",
       title = "a  cover_tall is a share of footprints that reach 5 m, not a canopy cover",
       subtitle = "It saturates near 100% while true cover still varies; first-return cover\nat the same footprints follows the wall-to-wall value.") +
  theme(legend.position = "bottom", panel.border = element_rect(fill = NA, colour = "grey85"))
p18b <- ggplot(TM, aes(als_hmed, sat_hmed, colour = sensor)) + geom_abline(slope = 1, intercept = 0, linewidth = 0.3) +
  geom_point(aes(size = n), alpha = 0.7) + scale_colour_manual(values = SENSOR, guide = "none") + scale_size_area(max_size = 3, name = "Samples\nin tile") +
  facet_wrap(~sensor) + coord_fixed() +
  labs(x = "ALS at the same samples: median top height (m)", y = "Satellite h_med (m)",
       title = "b  h_med per tile against ALS on the same samples",
       subtitle = sprintf("Tiles with \u2265 10 GEDI footprints or \u2265 5 ICESat-2 segments (default\nfilters, no post-ALS harvest): %d and %d tiles.", nrow(TM[sensor == "GEDI L2A"]), nrow(TM[sensor == "ICESat-2 ATL08"]))) +
  theme(legend.position = "bottom", panel.border = element_rect(fill = NA, colour = "grey85"))
p18 <- (p18a | p18b) + plot_annotation(title = "The guide's polygon metrics on 1 km\u00b2 tiles, checked against ALS",
                                        theme = theme(plot.title = element_text(face = "bold", size = 13)))
save(p18, "18_tile_polygon_metrics_vs_als.png", 14, 6.6)

writeLines(capture.output(sessionInfo()), file.path(OUTC, "sessionInfo_11.txt"))
cat("Done. Numbers in", NUM, "\n")
