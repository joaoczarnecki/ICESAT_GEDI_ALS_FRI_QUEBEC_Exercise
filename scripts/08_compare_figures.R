###############################################################################
# 08_compare_figures.R - ICESat-2 and GEDI against the ALS metrics of the Québec PEP plots (province-wide)
#
# Author:    João Paulo Czarnecki de Liz (developer)
# Co-author: Claude (Anthropic), AI coding assistant
# Licence:   MIT (see LICENSE)
#
# A pair = one satellite sample within 100 m of one plot centre, after the default quality filters (GEDI
# leaf-on flag and sensitivity >= 0.95; ATL08 strong beams, snow-free), June-September 2019-2025.
# Compared metrics (plot ALS from data/plot_als_metrics.csv, 11.28 m plots):
#   GEDI RH95        <-> plot P95 of all returns (zq95)   same definition
#   GEDI RH50        <-> plot P50 (zq50)                  same definition
#   ATL08 h_canopy   <-> plot P95 (zq95)                  close, not identical (P98 of canopy photons over 100 m)
# "On the plot": a GEDI footprint overlapping the plot (centre <= 25 m); an ICESat-2 segment crossing it
# (tracks run nearly north-south here: |east offset| <= 18 m and |north offset| <= 61 m).
# Delay = satellite date - ALS date (years; negative when the satellite came first). A pair is "disturbed" when
# an MRNF harvest, partial cut, fire or other event falls between the ALS year and the satellite year.
# 95% intervals: bootstrap over plots (the pairs of one plot share its ALS and its ground).
#
# Run    Rscript scripts/08_compare_figures.R          (~5 min)
# Inputs data/derived/plots_province.csv, plot_events_2010plus.csv (step 7);
#        data/derived/gedi02a_plots.csv, atl08_plots.csv (step 5) or the copies provided in data/satellite/
# Output docs/assets/img/P1-P4_*.png (the figures of the site), outputs/*.csv, outputs/numbers.txt
###############################################################################
suppressPackageStartupMessages({ library(sf); library(ggplot2); library(patchwork); library(data.table); library(scales) })
sf_use_s2(FALSE); invisible(Sys.setlocale("LC_TIME", "C"))
ROOT <- Sys.getenv("EXERCISE_ROOT", ".")
DAT  <- file.path(ROOT, "data/derived")
FIG  <- Sys.getenv("FIG_DIR", file.path(ROOT, "docs/assets/img")); OUTP <- Sys.getenv("OUT_DIR", file.path(ROOT, "outputs"))
dir.create(FIG, showWarnings = FALSE, recursive = TRUE); dir.create(OUTP, showWarnings = FALSE, recursive = TRUE)
sat_file <- function(f) { p <- file.path(DAT, f); if (file.exists(p)) p else file.path(ROOT, "data/satellite", f) }
source(file.path(ROOT, "scripts/summarise_lidar_by_polygon.R"))        # read_lidar(), lidar_filter()
set.seed(1)
NUM <- file.path(OUTP, "numbers.txt"); cat("", file = NUM)
say <- function(...) { s <- sprintf(...); cat(s, "\n"); cat(s, "\n", file = NUM, append = TRUE) }

# --- look -----------------------------------------------------------------------------------
SENSOR <- c("GEDI L2A" = "#eb6834", "ICESat-2 ATL08" = "#2a78d6")
FT_PAL <- c("Softwood" = "#1f7a4d", "Mixed" = "#7d55d0", "Hardwood" = "#c47a00", "Open / regenerating" = "#8e8e8e")
LEAF_ON  <- "Leaf-on ALS (June–September)"
LEAF_OFF <- "Leaf-off or transition ALS (April–May, October–December)"
SEASON_PAL <- setNames(c("#5b8c00", "#c2479a"), c(LEAF_ON, LEAF_OFF))
EV_PAL <- c("No MRNF event" = "#333333", "Harvest, cut or fire in between" = "#c2479a")
INK2 <- "grey35"
theme_set(theme_minimal(base_size = 10) +
            theme(panel.grid.minor = element_blank(), plot.title = element_text(face = "bold", size = 12),
                  plot.title.position = "plot", plot.subtitle = element_text(colour = INK2),
                  strip.text = element_text(face = "bold"), panel.border = element_rect(fill = NA, colour = "grey88")))
save <- function(p, f, w, h) { ggsave(file.path(FIG, f), p, width = w, height = h, dpi = 200, bg = "white"); cat("  wrote", f, "\n") }
fmt  <- function(x, d = 0) formatC(x, format = "f", digits = d, big.mark = ",")
rmse <- function(x) sqrt(mean(x^2))
st   <- function(s, a) { d <- s - a; data.table(n = length(d), r = cor(s, a), bias = mean(d), rmse = rmse(d), mae = mean(abs(d))) }
lab  <- function(x) sprintf("n = %s pairs (%s plots)\nr = %.2f\nbias = %+.1f m\nRMSE = %.1f m", fmt(x$n), fmt(x$plots), x$r, x$bias, x$rmse)
boot_plot <- function(d, fun, B = 300) {                 # 95% interval, resampling whole plots
  if (!nrow(d)) return(c(NA_real_, NA_real_))
  idx <- split(seq_len(nrow(d)), d$plot_id)
  v <- replicate(B, fun(d[unlist(idx[sample(length(idx), replace = TRUE)], use.names = FALSE)]))
  as.numeric(quantile(v, c(0.025, 0.975), na.rm = TRUE))
}

# --- data -----------------------------------------------------------------------------------
P <- fread(file.path(DAT, "plots_province.csv"))
P[, als_date := as.Date(als_date)]
P[, als_season := factor(fifelse(als_month %in% 6:9, LEAF_ON, LEAF_OFF), levels = c(LEAF_ON, LEAF_OFF))]
P[, forest_type := factor(forest_type, levels = names(FT_PAL))]
EV <- fread(file.path(DAT, "plot_events_2010plus.csv"))
pxy <- st_coordinates(st_transform(st_as_sf(P, coords = c("longitude", "latitude"), crs = 4326), 32198))
P[, `:=`(px = pxy[, 1], py = pxy[, 2])]

prep <- function(file, product, sensor) {
  d <- as.data.table(lidar_filter(read_lidar(file), product))
  xy <- st_coordinates(st_transform(st_as_sf(d[, .(lon, lat)], coords = c("lon", "lat"), crs = 4326), 32198))
  d[, `:=`(sx = xy[, 1], sy = xy[, 2], sat_date = as.Date(substr(as.character(time), 1, 10)), sensor = sensor)]
  d <- merge(d, P[, .(plot_id, px, py, plon = longitude, plat = latitude, als_date, als_year, als_season, forest_type,
                      dom_bio, zq95, zq50, zmax)], by = "plot_id")
  d[, `:=`(dist = sqrt((sx - px)^2 + (sy - py)^2), gap = as.numeric(sat_date - als_date) / 365.25,
           dE = (lon - plon) * cos(plat * pi / 180) * 111320, dN = (lat - plat) * 110574)]
  d <- d[dist <= 100 & month(sat_date) %in% 6:9]
  d[, on_plot := if (product == "atl08") abs(dE) <= 18 & abs(dN) <= 61 else dist <= 25]
  e <- merge(d[, .(row = .I, plot_id, y0 = pmin(als_year, year(sat_date)), y1 = pmax(als_year, year(sat_date)))], EV,
             by = "plot_id", allow.cartesian = TRUE)[year >= y0 & year <= y1]
  d[, event := "No MRNF event"]; d[unique(e$row), event := "Harvest, cut or fire in between"]
  d
}
G <- prep(sat_file("gedi02a_plots.csv"), "gedi02a", "GEDI L2A")
A <- prep(sat_file("atl08_plots.csv"), "atl08", "ICESat-2 ATL08")
G[, `:=`(sat = rh95, als = zq95)]; A[, `:=`(sat = h, als = zq95)]
fwrite(G[, .(plot_id, time, beam, dist, on_plot, gap, event, rh95, rh50, rh98, zq95, zq50, sensitivity, forest_type, als_season)],
       file.path(OUTP, "pairs_gedi.csv"))
fwrite(A[, .(plot_id, time_ns, spot, dist, dE, dN, on_plot, gap, event, h, zq95, forest_type, als_season)], file.path(OUTP, "pairs_atl08.csv"))
say("Plots with ALS metrics: %s (south of 51.6N: %s)", fmt(nrow(P)), fmt(sum(P$latitude < 51.6)))
say("Pairs within 100 m after filters: GEDI %s (%s plots), ATL08 %s (%s plots)",
    fmt(nrow(G)), fmt(uniqueN(G$plot_id)), fmt(nrow(A)), fmt(uniqueN(A$plot_id)))

###############################################################################
# P1 How many plots have a satellite sample nearby
###############################################################################
cat("figure P1\n")
cnt <- rbindlist(lapply(c(12.5, 25, 50, 100), function(r) rbind(
  data.table(sensor = "GEDI L2A", r = r, plots = uniqueN(G[dist <= r]$plot_id), pairs = nrow(G[dist <= r])),
  data.table(sensor = "ICESat-2 ATL08", r = r, plots = uniqueN(A[dist <= r]$plot_id), pairs = nrow(A[dist <= r])))))
fwrite(cnt, file.path(OUTP, "table_plots_with_samples.csv"))
for (i in seq_len(nrow(cnt))) with(cnt[i], say("%s within %.1f m: %s plots, %s pairs", sensor, r, fmt(plots), fmt(pairs)))
onG <- unique(G[on_plot == TRUE]$plot_id); onA <- unique(A[on_plot == TRUE]$plot_id)
say("Plots with a sample ON the plot: GEDI %s (%s pairs), ICESat-2 %s (%s pairs), both %s",
    fmt(length(onG)), fmt(sum(G$on_plot)), fmt(length(onA)), fmt(sum(A$on_plot)), fmt(length(intersect(onG, onA))))
qc <- rnaturalearth::ne_states(country = "Canada", returnclass = "sf")
qc <- qc[qc$name %in% c("Québec", "Quebec"), ]
P[, near := factor(fifelse(plot_id %in% onG & plot_id %in% onA, "Both",
                    fifelse(plot_id %in% onG, "GEDI only", fifelse(plot_id %in% onA, "ICESat-2 only", "Neither"))),
                   levels = c("Neither", "ICESat-2 only", "GEDI only", "Both"))]
NEAR_PAL <- c("Neither" = "grey80", "ICESat-2 only" = SENSOR[[2]], "GEDI only" = SENSOR[[1]], "Both" = "black")
p1a <- ggplot() + geom_sf(data = qc, fill = "grey97", colour = "grey60", linewidth = 0.3) +
  geom_point(data = P[order(near)], aes(longitude, latitude, colour = near), size = 0.4, shape = 16) +
  geom_hline(yintercept = 51.6, colour = SENSOR[[1]], linetype = "22", linewidth = 0.4) +
  annotate("text", x = -79.6, y = 51.85, label = "GEDI stops at 51.6°N", hjust = 0, size = 2.7, colour = "grey20") +
  scale_colour_manual(values = NEAR_PAL, name = "Sample on the plot:") +
  guides(colour = guide_legend(override.aes = list(size = 2.5))) +
  coord_sf(xlim = c(-80, -57), ylim = c(44.8, 53), crs = 4326) +
  theme(axis.title = element_blank(), legend.position = "bottom") +
  labs(title = "a  Plots with a satellite sample on top of them",
       subtitle = sprintf("%s PEP plots with ALS metrics. Satellites: June–September 2019–2025, default filters.\nGEDI footprint overlapping the plot; ICESat-2 segment crossing it.", fmt(nrow(P))))
cnt[, sensor := factor(sensor, levels = names(SENSOR))]
p1b <- ggplot(cnt, aes(factor(r), plots, fill = sensor)) + geom_col(position = position_dodge(0.75), width = 0.7) +
  geom_text(aes(label = fmt(plots)), position = position_dodge(0.75), vjust = -0.4, size = 2.8, colour = "grey15") +
  scale_fill_manual(values = SENSOR, name = NULL) + scale_y_continuous(labels = comma, expand = expansion(mult = c(0, 0.1))) +
  labs(x = "Distance from the plot centre (m)", y = "Plots with at least one sample", title = "b  How many plots, by distance",
       subtitle = "Plot radius 11.28 m; GEDI footprint radius 12.5 m") +
  theme(legend.position = "bottom", panel.grid.major.x = element_blank())
save((p1a | p1b) + plot_layout(widths = c(1.5, 1)), "P1_plots_with_samples.png", 12.5, 6.2)

###############################################################################
# P2 Agreement on the plot, and how it degrades with distance
###############################################################################
cat("figure P2\n")
NEAR_GAP <- 2                                                       # |delay| <= 2 years
core <- function(d) d[on_plot == TRUE & abs(gap) <= NEAR_GAP & event == "No MRNF event"]
Gc <- core(G); Ac <- core(A)
sG <- cbind(st(Gc$sat, Gc$als), plots = uniqueN(Gc$plot_id)); sA <- cbind(st(Ac$sat, Ac$als), plots = uniqueN(Ac$plot_id))
sG50 <- cbind(st(Gc$rh50, Gc$zq50), plots = uniqueN(Gc$plot_id))
say("On the plot, |delay| <= %d y, no event. GEDI RH95 vs zq95: %s plots, n=%d, r=%.2f, bias=%+.2f, RMSE=%.2f, MAE=%.2f | RH50 vs zq50: r=%.2f, bias=%+.2f, RMSE=%.2f",
    NEAR_GAP, fmt(sG$plots), sG$n, sG$r, sG$bias, sG$rmse, sG$mae, sG50$r, sG50$bias, sG50$rmse)
say("On the plot, |delay| <= %d y, no event. ATL08 h_canopy vs zq95: %s plots, n=%d, r=%.2f, bias=%+.2f, RMSE=%.2f, MAE=%.2f",
    NEAR_GAP, fmt(sA$plots), sA$n, sA$r, sA$bias, sA$rmse, sA$mae)
for (q in list(list("GEDI", Gc), list("ATL08", Ac))) {
  x <- q[[2]][, .(e = sat - als)]
  say("  %s error quantiles (5, 25, 50, 75, 95%%): %s; share |error| > 5 m: %.0f%%", q[[1]],
      paste(sprintf("%+.1f", quantile(x$e, c(.05, .25, .5, .75, .95))), collapse = ", "), 100 * mean(abs(x$e) > 5))
}
sc <- function(d, s, sen, xl, yl, title) {
  lim <- c(0, quantile(c(d$sat, d$als), 0.998))
  ggplot(d, aes(als, sat)) + geom_bin2d(binwidth = c(1, 1)) +
    scale_fill_gradient(low = "#efefef", high = SENSOR[[sen]], trans = "log10", name = "Pairs") +
    geom_abline(slope = 1, intercept = 0, linewidth = 0.4) +
    annotate("label", x = lim[1], y = lim[2], label = lab(s), hjust = 0, vjust = 1, size = 2.7, fill = alpha("white", 0.85),
             border.colour = NA, colour = "grey15") +
    coord_fixed(xlim = lim, ylim = lim) + labs(x = xl, y = yl, title = title) + theme(legend.key.width = unit(0.3, "cm"))
}
p2a <- sc(Gc, sG, "GEDI L2A", "Plot ALS P95 (m)", "GEDI RH95 (m)", "a  GEDI footprint overlapping the plot")
p2b <- sc(Ac, sA, "ICESat-2 ATL08", "Plot ALS P95 (m)", "ATL08 h_canopy (m)", "b  ICESat-2 segment crossing the plot")
RINGS <- c(0, 12.5, 25, 50, 75, 100)
ring_tab <- function(d, sen) rbindlist(lapply(2:length(RINGS), function(k) {
  x <- d[dist > RINGS[k - 1] & dist <= RINGS[k] & abs(gap) <= NEAR_GAP & event == "No MRNF event"]
  b <- boot_plot(x, function(y) rmse(y$sat - y$als))
  data.table(sensor = sen, r = RINGS[k], rmse = if (nrow(x)) rmse(x$sat - x$als) else NA_real_, lo = b[1], hi = b[2], n = nrow(x))
}))
DB <- rbind(ring_tab(G, "GEDI L2A"), ring_tab(A, "ICESat-2 ATL08"))[n >= 20]
DB[, sensor := factor(sensor, levels = names(SENSOR))]
fwrite(DB, file.path(OUTP, "table_rmse_by_distance.csv"))
for (i in seq_len(nrow(DB))) with(DB[i], say("RMSE by distance ring, %s, to %.1f m: %.2f m (%.2f-%.2f), n=%d", sensor, r, rmse, lo, hi, n))
p2c <- ggplot(DB, aes(r, rmse, colour = sensor)) + geom_errorbar(aes(ymin = lo, ymax = hi), width = 0, linewidth = 0.6) +
  geom_line(linewidth = 0.6) + geom_point(size = 2) + scale_colour_manual(values = SENSOR, name = NULL) +
  scale_x_continuous(breaks = RINGS[-1]) + expand_limits(y = 0) +
  labs(x = "Distance ring from the plot centre (outer edge, m)", y = "RMSE against plot ALS P95 (m)",
       title = "c  Error by distance from the plot", subtitle = "Rings 0–12.5, 12.5–25, 25–50, 50–75, 75–100 m") +
  theme(legend.position = "bottom")
save((p2a | p2b | p2c) + plot_annotation(
  title = "When a satellite sample falls on an inventory plot, how close is it to the plot's ALS?",
  subtitle = sprintf("ALS and satellite within %d years of each other, no MRNF harvest, cut or fire in between. GEDI RH95 and the plot P95 have the same definition;\nATL08 h_canopy (98th percentile of canopy photons over 100 m) is close but not identical. 95%% intervals: bootstrap over plots.", NEAR_GAP),
  theme = theme(plot.title = element_text(face = "bold", size = 13))), "P2_agreement_at_the_plot.png", 15, 5.8)

###############################################################################
# P3 Delay between the ALS and the satellite: how much uncertainty it adds
###############################################################################
# Across plots the delay is confounded with the region (each region was flown in a different year). Two ways
# around it: (a, b) one line per ALS period, so that each line follows the same plots through the satellite
# years; (numbers) a within-plot estimate, from plots seen on the plot at two or more different delays.
cat("figure P3\n")
ALS_GRP <- function(y) cut(y, c(2008, 2016, 2018, 2020, 2022, 2025),
                           labels = c("2009–2016", "2017–2018", "2019–2020", "2021–2022", "2023–2025"))
GRP_PAL <- setNames(c("#c9c0f2", "#a99bec", "#7d68dc", "#5340b8", "#2c1f7a"), levels(ALS_GRP(2010)))
DELAY_R <- 50; WITHIN_R <- 100        # samples used for the delay lines / for the within-plot estimate (m)
mk <- function(r) { x <- rbind(G[dist <= r, .(sensor, plot_id, gap, als_year, event, e = sat - als)],
                               A[dist <= r, .(sensor, plot_id, gap, als_year, event, e = sat - als)])
  x[, `:=`(gbin = round(gap), grp = ALS_GRP(als_year), sensor = factor(sensor, levels = names(SENSOR)))][] }
DD <- mk(DELAY_R); DW <- mk(WITHIN_R)
T3 <- DD[event == "No MRNF event", { b1 <- boot_plot(.SD, function(x) rmse(x$e)); b2 <- boot_plot(.SD, function(x) mean(x$e))
  .(rmse = rmse(e), rmse_lo = b1[1], rmse_hi = b1[2], bias = mean(e), bias_lo = b2[1], bias_hi = b2[2], n = .N, plots = uniqueN(plot_id)) },
  by = .(sensor, grp, gbin)][n >= 20]
fwrite(T3, file.path(OUTP, "table_error_by_delay.csv"))
within_plot <- function(d) {                    # slopes after removing each plot's own mean
  d <- d[event == "No MRNF event" & abs(e) < 15]
  d <- d[, if (uniqueN(gbin) >= 2) .SD, by = plot_id]
  if (uniqueN(d$plot_id) < 20) return(NULL)
  d[, `:=`(e2 = e^2, ag = abs(gap))]
  d[, `:=`(e2d = e2 - mean(e2), agd = ag - mean(ag), ed = e - mean(e), gd = gap - mean(gap)), by = plot_id]
  slope <- function(x) c(sum(x$e2d * x$agd) / sum(x$agd^2), sum(x$ed * x$gd) / sum(x$gd^2))
  est <- slope(d); idx <- split(seq_len(nrow(d)), d$plot_id)
  b <- replicate(300, slope(d[unlist(idx[sample(length(idx), replace = TRUE)])]))
  r0 <- sqrt(mean(d[ag <= 1]$e2))
  list(n = nrow(d), plots = uniqueN(d$plot_id), b2 = est[1], b2_ci = quantile(b[1, ], c(.025, .975), na.rm = TRUE),
       drift = est[2], drift_ci = quantile(b[2, ], c(.025, .975), na.rm = TRUE), r0 = r0,
       r5 = sqrt(max(r0^2 + 5 * est[1], 0)), r10 = sqrt(max(r0^2 + 10 * est[1], 0)))
}
W <- list()
for (sn in names(SENSOR)) {
  W[[sn]] <- w <- within_plot(DW[sensor == sn])
  if (is.null(w)) say("Within-plot delay, %s: fewer than 20 plots seen at two or more delays", sn)
  else say("Within-plot delay, %s: %d pairs on %d plots; squared error %+.2f m2/yr (95%% %.2f to %.2f) -> RMSE %.2f m at <= 1 yr, %.2f at 5, %.2f at 10; difference drifts %+.2f m/yr (%.2f to %.2f)",
           sn, w$n, w$plots, w$b2, w$b2_ci[1], w$b2_ci[2], w$r0, w$r5, w$r10, w$drift, w$drift_ci[1], w$drift_ci[2])
  x <- DD[sensor == sn]
  say("  %s within %d m: %.1f%% of pairs with an MRNF event in between; RMSE %.2f m with, %.2f m without",
      sn, DELAY_R, 100 * mean(x$event != "No MRNF event"), rmse(x[event != "No MRNF event"]$e), rmse(x[event == "No MRNF event"]$e))
}
WL <- rbindlist(lapply(names(SENSOR), function(sn) { w <- W[[sn]]
  data.table(sensor = factor(sn, levels = names(SENSOR)),
             lab = if (is.null(w)) "Too few plots seen at several delays" else
               sprintf("Within-plot estimate (samples ≤ %d m): RMSE %.1f m at ≤ 1 year,\n%.1f m at 5 years, %.1f m at 10 years (%s plots)", WITHIN_R, w$r0, w$r5, w$r10, fmt(w$plots))) }))
p3a <- ggplot(T3, aes(gbin, rmse, colour = grp)) + geom_vline(xintercept = 0, colour = "grey70", linewidth = 0.3) +
  geom_line(linewidth = 0.6) + geom_point(size = 1.6) +
  geom_text(data = WL, aes(x = -Inf, y = Inf, label = lab), inherit.aes = FALSE, hjust = -0.03, vjust = 1.2, size = 2.7, colour = "grey15") +
  facet_wrap(~sensor, drop = FALSE) + scale_colour_manual(values = GRP_PAL, name = "ALS flown in", drop = FALSE) +
  scale_y_continuous(expand = expansion(mult = c(0.02, 0.3))) + expand_limits(y = 0) +
  labs(x = NULL, y = "RMSE against plot ALS P95 (m)", title = "a  Uncertainty against the delay",
       subtitle = "One line per ALS period: along a line the plots are the same and only the satellite year changes. Pairs without an MRNF event; points with < 20 pairs hidden.")
p3b <- ggplot(T3, aes(gbin, bias, colour = grp)) + geom_hline(yintercept = 0, colour = "grey60", linewidth = 0.3) +
  geom_vline(xintercept = 0, colour = "grey70", linewidth = 0.3) + geom_line(linewidth = 0.6) + geom_point(size = 1.6) +
  facet_wrap(~sensor, drop = FALSE) + scale_colour_manual(values = GRP_PAL, guide = "none", drop = FALSE) +
  labs(x = "Delay: satellite date − ALS date (years; negative = satellite first)", y = "Mean difference,\nsatellite − ALS (m)",
       title = "b  Mean difference against the delay (growth shows as a rising line)")
T3e <- DD[, .(rmse = rmse(e), n = .N), by = .(sensor, event)]
T3e[, event := factor(event, levels = names(EV_PAL))]
p3c <- ggplot(T3e, aes(event, rmse, fill = event)) + geom_col(width = 0.6) + facet_wrap(~sensor) +
  geom_text(aes(label = sprintf("%.1f m\n(%s pairs)", rmse, fmt(n))), vjust = -0.2, size = 2.7, colour = "grey15", lineheight = 0.9) +
  scale_fill_manual(values = EV_PAL, guide = "none") + scale_y_continuous(expand = expansion(mult = c(0, 0.35))) +
  labs(x = NULL, y = "RMSE (m)", title = "c  All delays: pairs with and without a disturbance in between") +
  theme(panel.grid.major.x = element_blank())
save((p3a / p3b / p3c) + plot_layout(heights = c(1.25, 1, 0.8)) + plot_annotation(
  title = "How much the delay between the ALS and the satellite costs",
  subtitle = sprintf("Samples within %d m of the plot centre at every delay: ALS 2009–2025, satellites June–September 2019–2025.", DELAY_R),
  theme = theme(plot.title = element_text(face = "bold", size = 13))), "P3_delay_uncertainty.png", 12, 10.5)

###############################################################################
# P4 Forest type and ALS season
###############################################################################
cat("figure P4\n")
GAP4 <- 3
ft_tab <- function(d, sen) d[!is.na(forest_type), {
  b1 <- boot_plot(.SD, function(x) mean(x$sat - x$als)); b2 <- boot_plot(.SD, function(x) rmse(x$sat - x$als))
  .(bias = mean(sat - als), bias_lo = b1[1], bias_hi = b1[2], rmse = rmse(sat - als), rmse_lo = b2[1], rmse_hi = b2[2],
    bias50 = if (sen == "GEDI L2A") mean(rh50 - zq50) else NA_real_, n = .N, plots = uniqueN(plot_id)) },
  by = .(forest_type, als_season)][, sensor := sen][]
T4 <- rbind(ft_tab(G[on_plot == TRUE & abs(gap) <= GAP4 & event == "No MRNF event"], "GEDI L2A"),
            ft_tab(A[on_plot == TRUE & abs(gap) <= GAP4 & event == "No MRNF event"], "ICESat-2 ATL08"))[n >= 20]
T4[, sensor := factor(sensor, levels = names(SENSOR))]
fwrite(T4, file.path(OUTP, "table_by_forest_type_and_als_season.csv"))
for (i in seq_len(nrow(T4))) with(T4[i], say("Forest %s | %s | %s: n=%d plots=%d bias=%+.2f RMSE=%.2f RH50-zq50=%+.2f",
                                              sensor, forest_type, als_season, n, plots, bias, rmse, bias50))
M_B <- "Mean difference, satellite − ALS (m)"; M_R <- "RMSE (m)"
T4l <- rbind(T4[, .(sensor, forest_type, als_season, n, stat = M_B, est = bias, lo = bias_lo, hi = bias_hi)],
             T4[, .(sensor, forest_type, als_season, n, stat = M_R, est = rmse, lo = rmse_lo, hi = rmse_hi)])
T4l[, stat := factor(stat, levels = c(M_B, M_R))]
p4 <- ggplot(T4l, aes(forest_type, est, colour = als_season, group = als_season)) +
  geom_hline(data = data.frame(stat = factor(M_B, levels = c(M_B, M_R)), y = 0), aes(yintercept = y), colour = "grey60", linewidth = 0.3) +
  geom_errorbar(aes(ymin = lo, ymax = hi), width = 0, linewidth = 0.6, position = position_dodge(0.5)) +
  geom_point(size = 2.2, position = position_dodge(0.5)) +
  geom_text(aes(y = hi, label = n), vjust = -0.5, size = 2.3, colour = INK2, position = position_dodge(0.5), show.legend = FALSE) +
  facet_grid(stat ~ sensor, scales = "free_y", switch = "y") + scale_colour_manual(values = SEASON_PAL, name = NULL) +
  scale_y_continuous(expand = expansion(mult = c(0.08, 0.15))) +
  labs(x = "Forest type of the plot (field tree tally)", y = NULL, title = "Agreement by forest type and by the season the ALS was flown",
       subtitle = sprintf("Samples on the plot, delay ≤ %d years, no MRNF event in between. Numbers = pairs; 95%% intervals: bootstrap over plots.\nThe satellites are always leaf-on (June–September).", GAP4)) +
  theme(legend.position = "bottom", strip.placement = "outside")
if (nrow(T4)) save(p4, "P4_forest_type_and_als_season.png", 11, 7.5)
writeLines(capture.output(sessionInfo()), file.path(OUTP, "sessionInfo.txt"))
cat("Done. Numbers in", NUM, "\n")
