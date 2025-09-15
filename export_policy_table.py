
import argparse
import json
import os
from typing import Dict, Any, List

import numpy as np
import pandas as pd
from joblib import load
import yaml


# ----------------- I/O -----------------

def read_config(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def load_model_and_meta(cfg: Dict[str, Any]):
    model = load(cfg["bc_model_path"])
    with open(cfg["meta_file"], "r", encoding="utf-8") as f:
        meta = json.load(f)
    return model, meta


# ----------------- Grid -----------------

def make_grid() -> pd.DataFrame:
    """
    Build the policy grid over which we query the BC model.
    NOTE: stages are 0..7 here so the CSV matches NetLogo exactly.
    """
    stages = list(range(0, 8))          # 0..7 (NetLogo crop-stage)
    months = list(range(1, 13))         # 1..12
    def_grid = [0, 1, 2, 3, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40]
    canal_mm = [0, 2, 5, 10, 15, 20, 30, 40, 60, 80, 100]
    pool_ratio = [round(x, 2) for x in np.linspace(0.0, 1.0, 11)]
    norm_day = [0.5]                    # mid-stage snapshot for table compactness

    grid = pd.MultiIndex.from_product(
        [stages, months, def_grid, def_grid, canal_mm, pool_ratio, norm_day],
        names=["stage", "month", "defN_mm", "defS_mm", "canal_mm", "pool_ratio", "norm_day"]
    ).to_frame(index=False)
    return grid


# ----------------- Features -----------------

def synth_features_df(grid: pd.DataFrame, meta: Dict[str, Any]) -> pd.DataFrame:
    """
    Build the exact feature matrix the model expects, in the correct order.
    - CSV/table stage is 0..7, but model feature 'stage' should see 1..8
    - Add robust flags for is_drain_stage / is_flood_stage handling both 0- and 1-based lists
    - Weather features default to 0
    """
    feat_names: List[str] = meta["features"]

    target_by_stage = np.asarray(
        meta.get("target_by_stage", [15, 35, 25, 0, 25, 25, 25, 0]),
        dtype=float
    )

    # Stages for the TABLE (0..7) and for the MODEL (1..8)
    stage_tbl = grid["stage"].to_numpy(dtype=int)
    stage_model = stage_tbl + 1

    # Targets & deficits -> north/south absolute mm
    target = target_by_stage[stage_tbl]  # index with 0..7
    defN = grid["defN_mm"].to_numpy(dtype=float)
    defS = grid["defS_mm"].to_numpy(dtype=float)
    north_mm = np.maximum(target - defN, 0.0)
    south_mm = np.maximum(target - defS, 0.0)

    # Other scalar inputs
    month = grid["month"].to_numpy(dtype=float)
    canal = grid["canal_mm"].to_numpy(dtype=float)
    pool_ratio = grid["pool_ratio"].clip(0, 1).to_numpy(dtype=float)
    norm_day = grid["norm_day"].to_numpy(dtype=float)

    # Stage flags — handle either 0-based or 1-based lists in meta
    drain_stages = np.asarray(meta.get("drain_stages", [3, 7]), dtype=int)
    flood_stages = np.asarray(meta.get("flood_stages", [1, 2, 5]), dtype=int)

    # If meta lists are 0-based, compare with stage_tbl; if 1-based, compare with stage_model.
    is_drain0 = np.isin(stage_tbl, drain_stages).astype(int)
    is_drain1 = np.isin(stage_model, drain_stages).astype(int)
    is_flood0 = np.isin(stage_tbl, flood_stages).astype(int)
    is_flood1 = np.isin(stage_model, flood_stages).astype(int)
    is_drain = np.maximum(is_drain0, is_drain1)
    is_flood = np.maximum(is_flood0, is_flood1)

    # Optional weather features default to 0.0
    rain_mm = np.zeros_like(month, dtype=float)
    loss_mm = np.zeros_like(month, dtype=float)

    # Build candidate feature dict (include all we know about)
    candidates = {
        # IMPORTANT: feed 1..8 stage to the MODEL
        "stage": stage_model.astype(float),
        "norm_day": norm_day,
        "month": month,
        "north_mm": north_mm,
        "south_mm": south_mm,
        "target_mm": target,
        "defN_mm": defN,
        "defS_mm": defS,
        "canal_mm": canal,
        "pool_ratio": pool_ratio,
        "is_drain_stage": is_drain.astype(float),
        "is_flood_stage": is_flood.astype(float),
        "rain_mm": rain_mm,
        "loss_mm": loss_mm,
    }

    # Keep only model features, preserve exact order; fill missing with 0.0 if any
    feat_cols = [c for c in feat_names if c in candidates]
    feats = pd.DataFrame({c: candidates[c] for c in feat_cols})
    feats = feats.reindex(columns=feat_names, fill_value=0.0)

    # Optional: warn if some expected features were filled (unlikely but helpful)
    missing = [c for c in feat_names if c not in candidates]
    if missing:
        print(f"[warn] Missing feature(s) not in candidates (filled with 0.0): {missing}")

    return feats


# ----------------- Prediction -----------------

def clip_and_round(y: np.ndarray, actions: List[str], limits: Dict[str, float]) -> pd.DataFrame:
    out = {}
    for j, a in enumerate(actions):
        v = y[:, j]
        if "irrigate" in a:
            v = np.clip(v, 0.0, float(limits.get("irrigate_max", 5.0)))
        else:
            v = np.clip(v, 0.0, float(limits.get("drain_max", 3.0)))
        out[a] = np.round(v, 3)
    return pd.DataFrame(out)


# ----------------- Main -----------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", "-c", default="config.yaml")
    ap.add_argument("--batch_size", type=int, default=200_000,
                    help="Prediction batch size to control memory/throughput.")
    args = ap.parse_args()

    cfg = read_config(args.config)
    model, meta = load_model_and_meta(cfg)

    # Build grid (stage 0..7 for the TABLE)
    grid = make_grid()

    # Features to the model (stage 1..8 to the MODEL)
    feats = synth_features_df(grid, meta)

    # Predict in batches
    N = len(grid)
    bs = max(1, int(args.batch_size))
    preds = []
    X = feats.to_numpy(dtype=float, copy=False)
    for start in range(0, N, bs):
        stop = min(start + bs, N)
        preds.append(model.predict(X[start:stop]))
    Y = np.vstack(preds)

    # Clip to action limits and round
    actions = meta["actions"]
    limits = meta.get("limits", {"irrigate_max": 5.0, "drain_max": 3.0})
    act_df = clip_and_round(Y, actions, limits)

    # Assemble final table (CSV uses 0..7 stage from the grid)
    out = pd.concat([
        grid[["stage", "month", "defN_mm", "defS_mm", "canal_mm", "pool_ratio"]].reset_index(drop=True),
        act_df.reset_index(drop=True)
    ], axis=1)

    # Save
    os.makedirs(os.path.dirname(cfg["policy_table_csv"]), exist_ok=True)
    out.to_csv(cfg["policy_table_csv"], index=False)

    print(f"Exported {len(out):,} rows -> {cfg['policy_table_csv']}")
    print("Columns:", list(out.columns))
    # Small spot-check for stage domain
    print("Stage domain in CSV:", sorted(out['stage'].unique().tolist()))


if __name__ == "__main__":
    main()
