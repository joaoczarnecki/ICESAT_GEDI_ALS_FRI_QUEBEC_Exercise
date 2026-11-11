###############################################################################
# 01_match_plots_to_tiles.R - find the airborne lidar (ALS) tile that covers each Québec permanent sample plot
#
# Author:    João Paulo Czarnecki de Liz (developer)
# Co-author: Claude (Anthropic), AI coding assistant
# Licence:   MIT (see LICENSE)
#
# Reads the PEP plot layer and the provincial lidar tile index, joins each plot to the tile(s) it falls in,
# keeps the most recent acquisition (PLUS_RECENTE = "Oui") and prefers classified point clouds over raw ones.
# The output lists, for each plot, the tile name, its EPSG zone, its acquisition date(s) and its download URL.
#
# Inputs  data/raw/PEP.gpkg          layer "placette" (Données Québec, Placettes-échantillons permanentes)
#         data/raw/Index_Lidar.gpkg  layer "Index_Tuiles_LiDAR" (Données Québec, Données lidar du Québec)
# Output  data/derived/plot_tiles.csv
# Run     Rscript scripts/01_match_plots_to_tiles.R          (~3 min; the tile index has ~900,000 polygons)
###############################################################################
suppressPackageStartupMessages({ library(sf) })
sf_use_s2(FALSE)
ROOT <- Sys.getenv("EXERCISE_ROOT", ".")
PEP  <- Sys.getenv("PEP_GPKG", file.path(ROOT, "data/raw/PEP.gpkg"))
IDX  <- Sys.getenv("LIDAR_INDEX_GPKG", file.path(ROOT, "data/raw/Index_Lidar.gpkg"))
OUT  <- file.path(ROOT, "data/derived"); dir.create(OUT, showWarnings = FALSE, recursive = TRUE)
stopifnot("Put PEP.gpkg in data/raw/ (see docs/01_setup_and_data.md)" = file.exists(PEP),
          "Put Index_Lidar.gpkg in data/raw/ (see docs/01_setup_and_data.md)" = file.exists(IDX))

plots <- st_read(PEP, layer = "placette", quiet = TRUE)
plots <- data.frame(plot_id = as.numeric(plots$id_pe), latitude = plots$latitude, longitude = plots$longitude)
plots <- st_as_sf(plots[!is.na(plots$latitude), ], coords = c("longitude", "latitude"), crs = 4326, remove = FALSE)
cat("PEP plots:", nrow(plots), "\n")

# Most recent acquisition only; if the SQL filter fails on the accented values, filter in R instead
tiles <- tryCatch(st_read(IDX, query = "SELECT * FROM Index_Tuiles_LiDAR WHERE PLUS_RECENTE = 'Oui'", quiet = TRUE),
                  error = function(e) NULL)
if (is.null(tiles) || !nrow(tiles)) {
  tiles <- st_read(IDX, layer = "Index_Tuiles_LiDAR", quiet = TRUE)
  tiles <- tiles[tiles$PLUS_RECENTE == "Oui", ]
}
cat("Tile records (most recent):", nrow(tiles), "\n")
tiles <- st_transform(tiles[, c("NOM_TUILE", "TELECHARGEMENT_TUILE", "PROJET", "TYPE_DONNEES", "DENSITE",
                                "CLASSIFICATION", "CODE_EPSG", "DATES_ACQUISITION", "CAPTEUR")], 4326)

j <- st_drop_geometry(st_join(plots, tiles, join = st_intersects, left = TRUE))
n_match <- table(j$plot_id)
# prefer classified ("Données classifiées") over raw ("Données brutes") when a plot falls in several records
j$type_rank <- ifelse(j$TYPE_DONNEES == "Données classifiées", 1L, ifelse(j$TYPE_DONNEES == "Données brutes", 2L, 3L))
j <- j[order(j$plot_id, j$type_rank), ]
best <- j[!duplicated(j$plot_id), ]
best$n_tile_matches <- as.integer(n_match[as.character(best$plot_id)])
best$url <- sub("\\?.*$", "", best$TELECHARGEMENT_TUILE)            # drop tracking parameters
best$tile_file_name <- ifelse(is.na(best$NOM_TUILE), NA, paste0(best$NOM_TUILE, ".LAZ"))
best$type_rank <- best$TELECHARGEMENT_TUILE <- NULL

write.csv(best, file.path(OUT, "plot_tiles.csv"), row.names = FALSE)
cat("Plots with a tile:", sum(!is.na(best$NOM_TUILE)), "| classified:",
    sum(best$TYPE_DONNEES == "Données classifiées", na.rm = TRUE),
    "| distinct tiles to download:", length(unique(na.omit(best$tile_file_name))), "\n")
cat("Acquisition years:\n"); print(table(substr(best$DATES_ACQUISITION, 1, 4)))
cat("Saved", file.path(OUT, "plot_tiles.csv"), "\n")
