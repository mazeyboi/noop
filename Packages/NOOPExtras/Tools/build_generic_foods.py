#!/usr/bin/env python3
"""Builds Sources/NOOPExtras/Resources/generic_foods.json from USDA FoodData Central SR Legacy.

Source: https://fdc.nal.usda.gov/download-datasets (SR Legacy, CSV, April 2018). USDA FoodData Central
data is in the public domain (CC0 1.0); it is credited in the app's Food settings screen.

Usage: build_generic_foods.py <unzipped FoodData_Central_sr_legacy_food_csv_2018-04 dir> <out.json>
Each food: n name, k kcal, p protein, c carbs, f fat, fi fiber, s sugar, sa salt (g, from sodium),
ca caffeine mg, al alcohol g (all per 100 g), sg/sn first household portion (grams, label).
"""
import csv
import json
import sys
from pathlib import Path

NUTRIENTS = {"1008": "k", "1003": "p", "1005": "c", "1004": "f", "1079": "fi", "2000": "s",
             "1093": "na", "1057": "ca", "1018": "al"}
SKIP_CATEGORIES = {"Baby Foods", "Restaurant Foods", "American Indian/Alaska Native Foods"}


def main(src: str, out: str) -> None:
    d = Path(src)
    cats = {r["id"]: r["description"] for r in csv.DictReader(open(d / "food_category.csv", encoding="utf-8"))}
    foods = {}
    for r in csv.DictReader(open(d / "food.csv", encoding="utf-8")):
        if cats.get(r["food_category_id"]) in SKIP_CATEGORIES:
            continue
        foods[r["fdc_id"]] = {"n": r["description"].strip()}
    for r in csv.DictReader(open(d / "food_nutrient.csv", encoding="utf-8")):
        key = NUTRIENTS.get(r["nutrient_id"])
        f = foods.get(r["fdc_id"])
        if key and f is not None and r["amount"]:
            f[key] = float(r["amount"])
    portions = {}
    for r in csv.DictReader(open(d / "food_portion.csv", encoding="utf-8")):
        if r["fdc_id"] in foods and r["gram_weight"]:
            portions.setdefault(r["fdc_id"], []).append(r)
    out_list = []
    for fid, f in foods.items():
        if "k" not in f:
            continue
        na = f.pop("na", 0.0)
        if na:
            f["sa"] = round(na * 2.5 / 1000, 3)
        for k in ("k", "p", "c", "f", "fi", "s", "ca", "al"):
            if k in f:
                f[k] = round(f[k], 2)
                if f[k] == 0:
                    del f[k]
        ps = sorted(portions.get(fid, []), key=lambda r: int(r["seq_num"] or 0))
        if ps:
            p = ps[0]
            amount = (p["amount"] or "1").rstrip("0").rstrip(".") if "." in (p["amount"] or "") else (p["amount"] or "1")
            label = " ".join(x for x in (amount, p["modifier"] or p["portion_description"]) if x).strip()
            f["sg"] = round(float(p["gram_weight"]), 1)
            if label:
                f["sn"] = label[:60]
        out_list.append(f)
    out_list.sort(key=lambda f: f["n"].lower())
    Path(out).write_text(json.dumps(out_list, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"{len(out_list)} foods -> {out}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
