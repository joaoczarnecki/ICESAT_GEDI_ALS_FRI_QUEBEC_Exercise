###############################################################################
# 02_download_laz.R - download the lidar tiles (LAZ) listed by 01_match_plots_to_tiles.R
#
# Author:    João Paulo Czarnecki de Liz (developer)
# Co-author: Claude (Anthropic), AI coding assistant
# Licence:   MIT (see LICENSE)
#
# One tile is 1 km x 1 km (about 20-150 MB). The whole province (~11,000 tiles, ~1 TB) takes a day or more;
# use TILE_LIMIT to try a few first. Files already on disk are skipped, so the script can be stopped and rerun.
#
# Input   data/derived/plot_tiles.csv
# Output  data/raw/laz/<NOM_TUILE>.LAZ, data/derived/download_log.csv
# Run     Rscript scripts/02_download_laz.R                  (all tiles of classified point clouds)
#         TILE_LIMIT=20 WORKERS=4 Rscript scripts/02_download_laz.R
#         TILE_LIST=data/derived/why/tiles_needed.csv Rscript scripts/02_download_laz.R   (only the tiles of step 9)
###############################################################################
suppressPackageStartupMessages({ library(curl); library(parallel) })
ROOT <- Sys.getenv("EXERCISE_ROOT", ".")
LAZ  <- Sys.getenv("LAZ_DIR", file.path(ROOT, "data/raw/laz")); dir.create(LAZ, showWarnings = FALSE, recursive = TRUE)
WORKERS <- as.integer(Sys.getenv("WORKERS", "4"))
LIMIT   <- as.integer(Sys.getenv("TILE_LIMIT", "0"))

pt <- read.csv(file.path(ROOT, "data/derived/plot_tiles.csv"), stringsAsFactors = FALSE)
pt <- pt[!is.na(pt$url) & pt$TYPE_DONNEES == "Données classifiées", ]
tiles <- unique(pt[, c("tile_file_name", "url")])
LIST <- Sys.getenv("TILE_LIST", "")                   # optional CSV with a tile_file_name column (e.g. step 9)
if (nzchar(LIST)) tiles <- tiles[tiles$tile_file_name %in% read.csv(LIST)$tile_file_name, ]
if (LIMIT > 0) tiles <- head(tiles, LIMIT)
cat("Tiles to get:", nrow(tiles), "| already on disk:", sum(file.exists(file.path(LAZ, tiles$tile_file_name))), "\n")

download_one <- function(url, dest, retries = 6) {
  if (file.exists(dest) && file.info(dest)$size > 0) return("exists")
  for (k in seq_len(retries)) {
    ok <- tryCatch({
      curl::curl_download(url, destfile = dest, quiet = TRUE, mode = "wb",
                          handle = curl::new_handle(followlocation = 1L, connecttimeout = 30L))
      file.exists(dest) && file.info(dest)$size > 0
    }, error = function(e) FALSE)
    if (ok) return("downloaded")
    Sys.sleep(min(60, 2^(k - 1)))                       # back off on a busy server
  }
  if (file.exists(dest)) unlink(dest)                    # no half-written file left behind
  "failed"
}

cl <- makeCluster(WORKERS)
res <- parLapplyLB(cl, seq_len(nrow(tiles)), function(i, tiles, LAZ, download_one)
  download_one(tiles$url[i], file.path(LAZ, tiles$tile_file_name[i])), tiles = tiles, LAZ = LAZ, download_one = download_one)
stopCluster(cl)
tiles$result <- unlist(res)
write.csv(tiles, file.path(ROOT, "data/derived/download_log.csv"), row.names = FALSE)
print(table(tiles$result))
