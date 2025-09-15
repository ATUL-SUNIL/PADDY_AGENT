import argparse, glob, json, os, warnings
from dataclasses import dataclass
from typing import List, Dict, Any, Tuple

import numpy as np
import pandas as pd
from sklearn.metrics import mean_absolute_error
from sklearn.model_selection import train_test_split
from sklearn.multioutput import MultiOutputRegressor
from sklearn.ensemble import RandomForestRegressor
from joblib import dump
import yaml

warnings.filterwarnings("ignore", category=FutureWarning)

# -------------------------- utils --------------------------

def read_config(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    return cfg

def list_csvs(glob_pat: str) -> List[str]:
    files = sorted(glob.glob(glob_pat))
    if not files:
        raise FileNotFoundError(f"No CSVs found for pattern: {glob_pat}")
    return files

def coerce_numeric(df: pd.DataFrame) -> pd.DataFrame:
    for c in df.columns:
        df[c] = pd.to_numeric(df[c], errors="ignore")
    return df

def compute_norm_day(df: pd.DataFrame, stage_durations: List[int]) -> pd.DataFrame:
    # stage is 1..8 in your CSVs; convert to int
    if "stage" not in df.columns:
        raise ValueError("CSV missing 'stage' column.")
    st = df["stage"].astype(int).values
    norm = np.zeros(len(df), dtype=float)
    count_in_stage = 0
    prev_stage = st[0]
    for i, s in enumerate(st):
        if s != prev_stage:
            count_in_stage = 0
            prev_stage = s
        dur = stage_durations[min(max(int(s)-1, 0), len(stage_durations)-1)]
        norm[i] = (count_in_stage / max(dur, 1))
        count_in_stage += 1
    df["norm_day"] = norm
    return df

def add_stage_flags(df: pd.DataFrame, drain_stages: List[int], flood_stages: List[int]) -> pd.DataFrame:
    df["is_drain_stage"] = df["stage"].astype(int).isin(drain_stages).astype(int)
    df["is_flood_stage"] = df["stage"].astype(int).isin(flood_stages).astype(int)
    return df

def ensure_columns(df: pd.DataFrame, required: List[str]) -> None:
    missing = [c for c in required if c not in df.columns]
    if missing:
        raise ValueError(f"CSV missing required columns: {missing}")

def safe_clip_actions(yhat: np.ndarray, limits: Dict[str, float], action_names: List[str]) -> np.ndarray:
    arr = yhat.copy()
    for j, a in enumerate(action_names):
        if "irrigate" in a:
            arr[:, j] = np.clip(arr[:, j], 0.0, float(limits.get("irrigate_max", 5.0)))
        elif "drain" in a:
            arr[:, j] = np.clip(arr[:, j], 0.0, float(limits.get("drain_max", 3.0)))
    return arr

# -------------------------- training --------------------------

@dataclass
class TrainArtifacts:
    model_path: str
    meta_path: str
    feature_names: List[str]
    action_names: List[str]
    train_mae: Dict[str, float]
    val_mae: Dict[str, float]
    n_rows: int
    n_files: int

def load_dataset(files: List[str],
                 cfg: Dict[str, Any]) -> Tuple[pd.DataFrame, pd.DataFrame]:
    stage_durations = cfg["stage_durations"]
    drain_stages = cfg["drain_stages"]
    flood_stages = cfg["flood_stages"]
    features_cfg = list(cfg["features"])
    action_names = list(cfg["actions"])

    # Optional columns that may or may not exist (backwards compatibility)
    optional_cols_defaults = {
        "rain_mm": 0.0,
        "loss_mm": 0.0,
        # keep names exactly as in logs (rain_today_mm -> rain_mm in header)
        # If your header uses 'rain_today_mm' / 'actual_loss_mm', map below:
        "rain_today_mm": 0.0,
        "actual_loss_mm": 0.0,
    }

    frames = []
    for f in files:
        df = pd.read_csv(f)
        df = coerce_numeric(df)

        # Back-compat: rename if your new logs use rain_today_mm/actual_loss_mm
        if ("rain_mm" not in df.columns) and ("rain_today_mm" in df.columns):
            df = df.rename(columns={"rain_today_mm": "rain_mm"})
        if ("loss_mm" not in df.columns) and ("actual_loss_mm" in df.columns):
            df = df.rename(columns={"actual_loss_mm": "loss_mm"})

        # Fill optional columns if missing
        for c, default in optional_cols_defaults.items():
            if c in ("rain_today_mm", "actual_loss_mm"):  # handled via rename above
                continue
            if c not in df.columns:
                df[c] = default

        # Deriveds
        df = compute_norm_day(df, stage_durations)
        df = add_stage_flags(df, drain_stages, flood_stages)

        # house-keeping
        df["pool_ratio"] = df["pool_ratio"].clip(0, 1)

        # sanity: ensure required columns exist
        ensure_columns(df, features_cfg + action_names)

        df["__ep__"] = os.path.splitext(os.path.basename(f))[0]  # for info
        frames.append(df)

    full = pd.concat(frames, ignore_index=True)
    # Drop any rows with NaNs in features/labels (shouldn’t happen, but safe)
    full = full.dropna(subset=features_cfg + action_names)
    return full[features_cfg], full[action_names]

def train(cfg: Dict[str, Any]) -> TrainArtifacts:
    data_glob = cfg["data_glob"]
    model_path = cfg["bc_model_path"]
    meta_path = cfg["meta_file"]
    features = list(cfg["features"])
    actions = list(cfg["actions"])
    tr = cfg["train"]
    limits = tr.get("limits", {"irrigate_max": 5.0, "drain_max": 3.0})

    files = list_csvs(data_glob)
    X, Y = load_dataset(files, cfg)

    X_train, X_val, Y_train, Y_val = train_test_split(
        X.values, Y.values, test_size=float(tr["val_split"]),
        shuffle=bool(tr.get("shuffle", True)), random_state=int(tr.get("seed", 42))
    )

    base = RandomForestRegressor(
        n_estimators=int(cfg["model"]["n_estimators"]),
        max_depth=int(cfg["model"]["max_depth"]),
        random_state=int(cfg["model"]["random_state"])
    )
    model = MultiOutputRegressor(base)
    model.fit(X_train, Y_train)

    # Evaluate
    Y_tr_hat = model.predict(X_train)
    Y_va_hat = model.predict(X_val)

    if bool(tr.get("clip_actions", True)):
        Y_tr_hat = safe_clip_actions(Y_tr_hat, limits, actions)
        Y_va_hat = safe_clip_actions(Y_va_hat, limits, actions)

    train_mae = {a: float(mean_absolute_error(Y_train[:, j], Y_tr_hat[:, j]))
                 for j, a in enumerate(actions)}
    val_mae = {a: float(mean_absolute_error(Y_val[:, j], Y_va_hat[:, j]))
               for j, a in enumerate(actions)}

    # Ensure dirs
    os.makedirs(os.path.dirname(model_path), exist_ok=True)

    # Save model + meta
    dump(model, model_path)
    meta = {
        "features": features,
        "actions": actions,
        "train_mae": train_mae,
        "val_mae": val_mae,
        "limits": limits,
        "stage_durations": cfg["stage_durations"],
        "drain_stages": cfg["drain_stages"],
        "flood_stages": cfg["flood_stages"],
        # Used by exporter to derive target_mm and north/south_mm from def*
        "target_by_stage": cfg.get("target_by_stage", [15, 35, 25, 0, 25, 25, 25, 0]),
    }
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)

    return TrainArtifacts(
        model_path=model_path,
        meta_path=meta_path,
        feature_names=features,
        action_names=actions,
        train_mae=train_mae,
        val_mae=val_mae,
        n_rows=int(X.shape[0]),
        n_files=len(files),
    )

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", "-c", default="config.yaml")
    args = ap.parse_args()

    cfg = read_config(args.config)
    arts = train(cfg)

    print("=== Training complete ===")
    print(f"Rows: {arts.n_rows}  Files: {arts.n_files}")
    print("Train MAE:", arts.train_mae)
    print(" Val  MAE:", arts.val_mae)
    print(f"Saved model -> {arts.model_path}")
    print(f"Saved meta  -> {arts.meta_path}")

if __name__ == "__main__":
    main()
