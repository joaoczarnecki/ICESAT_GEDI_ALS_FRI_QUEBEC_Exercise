###############################################################################
# 00_install_r_packages.R - R packages used by the exercise (tested with R 4.6.2 on Windows)
#
# Author:    João Paulo Czarnecki de Liz (developer)
# Co-author: Claude (Anthropic), AI coding assistant
# Licence:   MIT (see LICENSE)
#
# Run once: Rscript scripts/00_install_r_packages.R
###############################################################################
pk <- c("lidR",                    # point clouds: read LAZ, ground classification, normalisation, metrics
        "RCSF",                    # cloth simulation filter, used by lidR::csf() (not installed with lidR)
        "sf", "curl",              # vector data, downloads
        "data.table",              # fast tables
        "ggplot2", "patchwork", "scales",          # figures
        "rnaturalearth", "rnaturalearthhires")     # Québec outline for the maps
miss <- setdiff(pk, rownames(installed.packages()))
if ("rnaturalearthhires" %in% miss) {           # not on CRAN
  install.packages("rnaturalearthhires", repos = "https://ropensci.r-universe.dev")
  miss <- setdiff(miss, "rnaturalearthhires")
}
if (length(miss)) install.packages(miss, repos = "https://cloud.r-project.org")
for (p in pk) cat(sprintf("%-20s %s\n", p, if (requireNamespace(p, quietly = TRUE)) as.character(packageVersion(p)) else "MISSING"))
