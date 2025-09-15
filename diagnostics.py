import argparse, glob
from typing import Dict, Any, List
import yaml
import pandas as pd
import numpy as np

def read_config(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)

def scan(files: List[str], features: List[str], actions: List[str]) -> pd.DataFrame:
    recs = []
    for f in files:
        df = pd.read_csv(f)
        # Back-compat rename if needed
        if ("rain_mm" not in df.columns) and ("rain_today_mm" in df.columns):
            df = df.rename(columns={"rain_today_mm": "rain_mm"})
        if ("loss_mm" not in df.columns) and ("actual_loss_mm" in df.columns):
            df = df.rename(columns={"actual_loss_mm": "loss_mm"})
        issues = []
        # Required cols
        req = set(["stage","month","north_mm","south_mm","pool_mm","canal_mm","lake_mm",
                   "pool_ratio","irrigateN_mm","irrigateS_mm","drainN_mm","drainS_mm"])
        missing = sorted(list(req - set(df.columns)))
        if missing:
            issues.append(f"missing_cols:{missing}")

        # Ranges
        if "pool_ratio" in df:  # 0..1
            bad = ((df["pool_ratio"] < -1e-6) | (df["pool_ratio"] > 1+1e-6)).sum()
            if bad: issues.append(f"pool_ratio_out_of_range:{bad}")

        for c in ["north_mm","south_mm","pool_mm","canal_mm","lake_mm","rain_mm","loss_mm"]:
            if c in df:
                neg = (df[c] < -1e-9).sum()
                if neg: issues.append(f"{c}_neg:{neg}")
                if c in ("rain_mm","loss_mm"):
                    # absurdly large single-day values?
                    big = (df[c] > 150).sum()
                    if big: issues.append(f"{c}_very_large:{big}")

        na = df[ list(set(features+actions) & set(df.columns)) ].isna().sum().sum()
        if na: issues.append(f"NaNs:{int(na)}")

        # inconsistent stage progression?
        if "stage" in df:
            s = df["stage"].astype(int).values
            if (s.min()<1) or (s.max()>8):
                issues.append("stage_out_of_bounds")
        recs.append({"file": f, "issues": ";".join(issues) if issues else ""})
    return pd.DataFrame(recs)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", "-c", default="config.yaml")
    args = ap.parse_args()
    cfg = read_config(args.config)

    files = sorted(glob.glob(cfg["data_glob"]))
    df = scan(files, cfg["features"], cfg["actions"])
    print(df.to_string(index=False))
    print("\nFiles with issues:", (df["issues"]!="").sum(), "/", len(df))

if __name__ == "__main__":
    main()
