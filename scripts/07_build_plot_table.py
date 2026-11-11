"""
07_build_plot_table.py - one row per PEP plot with ALS metrics, ready to be paired with ICESat-2 and GEDI

Author:    João Paulo Czarnecki de Liz (developer)
Co-author: Claude (Anthropic), AI coding assistant
Licence:   MIT (see LICENSE)

Adds to the ALS metrics:
  * the ALS acquisition date and month (first date when a tile was flown on several days);
  * the bioclimatic domain (PEP table classi_eco_pe);
  * the forest type, from the live trees (dbh >= 9.1 cm) of the PEP measurement closest to the ALS date:
    softwood >= 75 % of the live basal area, hardwood >= 75 %, mixed otherwise, "Open / regenerating" when
    the live basal area is below 4 m2/ha;
  * the MRNF events from 2010 on that cover at least half of the plot, with their year, so that the comparison
    can drop a plot-satellite pair when an event falls between the two dates.

Input   data/raw/PEP.gpkg; data/plot_als_metrics.csv (or data/derived/plot_als_metrics_full.csv + plot_tiles.csv);
        data/plot_mrnf_events.csv (or data/derived/plot_mrnf_events.csv from step 6)
Output  data/derived/plots_province.csv, data/derived/plot_events_2010plus.csv
Run     python -I scripts/07_build_plot_table.py          (~2 min)
"""
import os
import sqlite3
import numpy as np
import pandas as pd

ROOT = os.environ.get("EXERCISE_ROOT", ".")
D, OUT = os.path.join(ROOT, "data"), os.path.join(ROOT, "data", "derived")
os.makedirs(OUT, exist_ok=True)
PEP = os.environ.get("PEP_GPKG", os.path.join(D, "raw", "PEP.gpkg"))
SOFTWOOD = {"SAB", "EPN", "EPB", "EPR", "EPO", "PIG", "PIB", "PIR", "PIS", "PRU", "THO", "MEL", "MEH", "MEJ", "MEU"}
LIVE = {"10", "12", "30", "32", "40", "42", "50", "52"}          # PEP tree-status codes of live trees
ALS = ["pt_density_m2", "zq50", "zq95", "zmax"]

# ALS metrics: your own extraction if it exists, else the table provided with the exercise
full = os.path.join(OUT, "plot_als_metrics_full.csv")
if os.path.exists(full):
    m = pd.read_csv(full); m = m[m.status == "ok"][["plot_id"] + ALS]
    p = pd.read_csv(os.path.join(OUT, "plot_tiles.csv"))[["plot_id", "latitude", "longitude", "DATES_ACQUISITION",
                                                         "CAPTEUR", "DENSITE"]].merge(m, on="plot_id")
else:
    p = pd.read_csv(os.path.join(D, "plot_als_metrics.csv"))
p["als_date"] = pd.to_datetime(p.DATES_ACQUISITION.str.split(",").str[0])
p["als_year"], p["als_month"] = p.als_date.dt.year, p.als_date.dt.month
p["id_pe"] = p.plot_id.astype(np.int64).astype(str).str.zfill(10)

con = sqlite3.connect(PEP)
eco = pd.read_sql("select id_pe, dom_bio, sdom_bio from classi_eco_pe", con)
mes = pd.read_sql("select id_pe, id_pe_mes, no_mes, date_sond from placette_mes", con)
mes = mes[mes.id_pe.isin(p.id_pe)].merge(p[["id_pe", "als_date"]], on="id_pe")
mes["field_date"] = pd.to_datetime(mes.date_sond.str[:10], errors="coerce")
mes["d"] = (mes.field_date - mes.als_date).abs()
pick = mes.sort_values("d").groupby("id_pe").head(1)                 # measurement closest to the ALS flight
tr = pd.read_sql("select id_pe_mes, etat, essence, st_ha from dendro_arbres", con)
tr = tr[tr.id_pe_mes.isin(pick.id_pe_mes) & tr.etat.isin(LIVE)]
tr["soft"] = tr.essence.isin(SOFTWOOD)
ba = tr.groupby("id_pe_mes").agg(ba_live=("st_ha", "sum"))
ba["soft_share"] = tr[tr.soft].groupby("id_pe_mes").st_ha.sum().reindex(ba.index).fillna(0) / ba.ba_live
pick = pick.merge(ba, left_on="id_pe_mes", right_index=True, how="left")
pick["forest_type"] = np.select([pick.ba_live.isna() | (pick.ba_live < 4), pick.soft_share >= 0.75, pick.soft_share <= 0.25],
                                ["Open / regenerating", "Softwood", "Hardwood"], "Mixed")
pick["field_year"] = pick.field_date.dt.year
p = p.merge(pick[["id_pe", "field_year", "ba_live", "soft_share", "forest_type"]], on="id_pe", how="left") \
     .merge(eco, on="id_pe", how="left")

evf = os.path.join(OUT, "plot_mrnf_events.csv")
ev = pd.read_csv(evf if os.path.exists(evf) else os.path.join(D, "plot_mrnf_events.csv"))
ev = ev[ev.plot_id.isin(p.plot_id) & (ev.overlap >= 0.5)].copy()
ev["year"] = ev.an_perturb.fillna(ev.an_origine).fillna(ev.exercice)        # year of the event, else of the record
ev = ev[ev.year >= 2010]
ev["kind"] = np.where(ev.layer == "ca_feu_close_scale", "fire",
                      np.where(ev.layer == "ca_interv_for_close_scale",
                               np.where(ev.origine.notna(), "harvest", "partial cut / tending"), "other natural"))
ev[["plot_id", "year", "kind", "origine", "perturb"]].to_csv(os.path.join(OUT, "plot_events_2010plus.csv"), index=False)
p.drop(columns=["id_pe"]).to_csv(os.path.join(OUT, "plots_province.csv"), index=False)
print(f"{len(p)} plots; forest types {p.forest_type.value_counts().to_dict()}")
print("ALS years:", p.als_year.value_counts().sort_index().to_dict())
print(f"{ev.plot_id.nunique()} plots with an MRNF event since 2010 ({len(ev)} events)")
