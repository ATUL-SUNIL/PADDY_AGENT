#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from itertools import product
from typing import List, Dict, Any

import joblib
import numpy as np
import pandas as pd

# ---- Defaults that mirror your NetLogo + sensible export grid ----------------

TARGET_BY_STAGE_DEFAULT = [15, 35, 25, 0, 25, 25, 25, 0]  # stage 0..7

DEFAULT_STAGES      = list(range(8))                # 0..7 (matches crop-stage)
DEFAULT_MONTHS      = list(range(1, 13))            # 1..12
DEFAULT_NORM_DAYS   = [0.5]                          # keep it compact
DEFAULT_DEF_BINS    = [0, 1, 2, 3, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40]
DEFAULT_CANAL_BINS  = [0, 2, 5, 10, 15, 20, 30, 40, 60, 80, 100]
DEFAULT_POOL_RATIOS = [round(x, 2) for x in np.linspace(0.0, 1.0, 11)]

# nominal values when model expects extra features
POOL_MM_SCALE   = 100.0
NOMINAL_LAKE_MM = 50.0
NOMINAL_WQ      = 0.0

# if meta lists more features than the model actually used, drop in this order
OPTIONAL_DROP_ORDER = [
    "lakeN_mgL","lakeP_mgL",
    "canalN_mgL","canalP_mgL",
    "poolN_mgL","poolP_mgL",
    "lake_mm","pool_mm",
    "rain_mm","loss_mm",
]

# -----------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser("Export a compact policy table from the BC model.")
    p.add_argument("--model", required=True, help="Path to models/bc_model.joblib")
    p.add_argument("--meta",  required=True, help="Path to models/bc_meta.json")
    p.add_argument("--out",   required=True, help="Path to models/policy_table.csv")
    p.add_argument("--batch_size", type=int, default=200_000)

    # grid controls
    p.add_argument("--stages",      nargs="*", type=int,   default=DEFAULT_STAGES)
    p.add_argument("--months",      nargs="*", type=int,   default=DEFAULT_MONTHS)
    p.add_argument("--norm_days",   nargs="*", type=float, default=DEFAULT_NORM_DAYS)
    p.add_argument("--def_bins",    nargs="*", type=float, default=DEFAULT_DEF_BINS)
    p.add_argument("--canal_bins",  nargs="*", type=float, default=DEFAULT_CANAL_BINS)
    p.add_argument("--pool_ratios", nargs="*", type=float, default=DEFAULT_POOL_RATIOS)

    # duplicate handling (e.g., if you include multiple norm_days)
    p.add_argument("--dedupe", choices=["first","median","mean","none"], default="first")
    return p.parse_args()

def load_meta(meta_path: Path) -> Dict[str, Any]:
    with open(meta_path, "r", encoding="utf-8") as f:
        meta = json.load(f)
    # normalize keys across older/newer training scripts
    meta["features"] = meta.get("features") or meta.get("feature_cols")
    meta["actions"]  = meta.get("actions")  or meta.get("target_cols") or meta.get("action_cols")
    if not meta.get("features") or not meta.get("actions"):
        raise ValueError("bc_meta.json must include 'features' and 'actions' (or compatible keys).")
    return meta

def align_features_to_model(feature_cols: List[str], model) -> List[str]:
    if not hasattr(model, "n_features_in_"):
        return feature_cols
    need = int(model.n_features_in_)
    have = len(feature_cols)
    if have == need:
        return feature_cols
    if have < need:
        raise ValueError(
            f"Model expects {need} features, meta lists {have}. "
            f"Retrain or fix bc_meta features order to exactly those used."
        )
    # drop extras in a controlled order
    pruned = feature_cols.copy()
    for c in [c for c in OPTIONAL_DROP_ORDER if c in pruned]:
        if len(pruned) == need:
            break
        pruned.remove(c)
    if len(pruned) != need:
        raise ValueError(
            f"Could not reconcile feature count: meta={have}, model={need}. "
            f"Edit bc_meta 'features' to the exact training set/order."
        )
    removed = [c for c in feature_cols if c not in pruned]
    if removed:
        print(f"[warn] Dropped extra features to match model: {removed}")
    return pruned

def build_grid(args, target_by_stage: List[float]) -> pd.DataFrame:
    recs = []
    for st, mo, nd, dN, dS, canal, pr in product(
        args.stages, args.months, args.norm_days, args.def_bins, args.def_bins, args.canal_bins, args.pool_ratios
    ):
        tgt = float(target_by_stage[int(st)])
        north_mm = max(tgt - float(dN), 0.0)
        south_mm = max(tgt - float(dS), 0.0)
        recs.append({
            "stage": int(st),
            "month": int(mo),
            "norm_day": float(nd),
            "defN_mm": float(dN),
            "defS_mm": float(dS),
            "canal_mm": float(canal),
            "pool_ratio": float(pr),
            "target_mm": tgt,
            "north_mm": north_mm,
            "south_mm": south_mm,
            # optional/nominal features (only used if the model expects them)
            "pool_mm": float(pr) * POOL_MM_SCALE,
            "lake_mm": NOMINAL_LAKE_MM,
            "poolN_mgL":  NOMINAL_WQ, "poolP_mgL":  NOMINAL_WQ,
            "canalN_mgL": NOMINAL_WQ, "canalP_mgL": NOMINAL_WQ,
            "lakeN_mgL":  NOMINAL_WQ, "lakeP_mgL":  NOMINAL_WQ,
            "rain_mm": 0.0, "loss_mm": 0.0,  # new weather features default to 0
        })
    return pd.DataFrame.from_records(recs)

def add_stage_flags(df: pd.DataFrame, drain_stages: List[int], flood_stages: List[int]) -> pd.DataFrame:
    df = df.copy()
    st = df["stage"].to_numpy()
    df["is_drain_stage"] = np.isin(st, np.asarray(drain_stages, dtype=int)).astype(float)
    df["is_flood_stage"] = np.isin(st, np.asarray(flood_stages, dtype=int)).astype(float)
    return df

def predict_in_batches(model, X: np.ndarray, batch_size: int) -> np.ndarray:
    preds = []
    n = X.shape[0]
    b = max(1, int(batch_size))
    for s in range(0, n, b):
        e = min(s + b, n)
        preds.append(model.predict(X[s:e]))
    return np.vstack(preds)

def clip_actions(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    for c in ("irrigateN_mm","irrigateS_mm"):
        if c in out.columns:
            out[c] = out[c].clip(0.0, 5.0)
    for c in ("drainN_mm","drainS_mm"):
        if c in out.columns:
            out[c] = out[c].clip(0.0, 3.0)
    return out

def dedupe(out: pd.DataFrame, how: str) -> pd.DataFrame:
    if how == "none":
        return out
    keys = ["stage","month","defN_mm","defS_mm","canal_mm","pool_ratio"]
    if how == "first":
        return out.drop_duplicates(subset=keys, keep="first").reset_index(drop=True)
    agg = {"irrigateN_mm":"median","irrigateS_mm":"median","drainN_mm":"median","drainS_mm":"median"} \
          if how == "median" else \
          {"irrigateN_mm":"mean","irrigateS_mm":"mean","drainN_mm":"mean","drainS_mm":"mean"}
    return out.groupby(keys, as_index=False).agg(agg).reset_index(drop=True)

def main():
    args = parse_args()

    model_path = Path(args.model)
    meta_path  = Path(args.meta)
    out_path   = Path(args.out)
    if not model_path.exists(): raise FileNotFoundError(model_path)
    if not meta_path.exists():  raise FileNotFoundError(meta_path)

    model = joblib.load(model_path)
    meta  = load_meta(meta_path)

    features: List[str] = meta["features"]
    actions:  List[str] = meta["actions"]

    # align features to the trained model (handles over-verbose meta safely)
    features = align_features_to_model(features, model)

    # stage targets & stage sets
    target_by_stage = meta.get("target_by_stage", TARGET_BY_STAGE_DEFAULT)
    drain_stages    = meta.get("drain_stages", [3, 7])
    flood_stages    = meta.get("flood_stages", [1, 2, 5])

    # grid
    grid = build_grid(args, target_by_stage)
    grid = add_stage_flags(grid, drain_stages, flood_stages)

    # ensure all expected features exist; fill missing with zeros (rare)
    for f in features:
        if f not in grid.columns:
            grid[f] = 0.0

    X = grid[features].to_numpy(dtype=float, copy=False)
    print(f"[info] model.n_features_in_: {getattr(model, 'n_features_in_', 'unknown')}")
    print(f"[info] features used: {features} (len={len(features)})")
    print(f"[info] actions: {actions}")
    print(f"[info] Grid rows: {len(grid):,}, X.shape: {X.shape}")

    # predict
    Y = predict_in_batches(model, X, args.batch_size)
    if Y.ndim == 1:
        Y = Y.reshape(-1, 1)
    if Y.shape[1] != len(actions):
        raise ValueError(f"Pred target dim {Y.shape[1]} != len(actions) {len(actions)}")

    ydf = pd.DataFrame(Y, columns=actions)
    ydf = clip_actions(ydf)

    out = pd.concat([
        grid[["stage","month","defN_mm","defS_mm","canal_mm","pool_ratio"]].reset_index(drop=True),
        ydf.reset_index(drop=True)
    ], axis=1)

    out = dedupe(out, args.dedupe).sort_values(
        by=["stage","month","defN_mm","defS_mm","canal_mm","pool_ratio"]
    ).reset_index(drop=True)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out.to_csv(out_path, index=False)

    st_dom = sorted(out["stage"].unique().tolist())
    print(f"[ok] Wrote policy table with {len(out):,} rows -> {out_path}")
    print(f"Stage domain in CSV: {st_dom}")

if __name__ == "__main__":
    main()
