import glob, pandas as pd

# === Step 1. Collect all rule + agent CSVs ===
rule_files = sorted(glob.glob("data/rule/rule_ep*.csv"))
agent_files = sorted(glob.glob("data/agent/agent_ep*.csv"))

def load_and_tag(files, label):
    dfs = []
    for f in files:
        df = pd.read_csv(f)
        df["source"] = label  # tag so we know if rule or agent
        dfs.append(df)
    return pd.concat(dfs, ignore_index=True)

rule_df = load_and_tag(rule_files, "rule")
agent_df = load_and_tag(agent_files, "agent")

# === Step 2. Merge together ===
data = pd.concat([rule_df, agent_df], ignore_index=True)

# === Step 3. Quick sanity checks ===
print("Episodes loaded:", len(rule_files), "rule +", len(agent_files), "agent")
print("Total rows:", len(data))

if "control_mode" in data.columns:
    print("Control modes:", data["control_mode"].value_counts())

print("Stage range:", data["stage"].min(), "to", data["stage"].max())
print("Any negative values?",
      (data[["north_mm","south_mm","pool_mm","canal_mm","lake_mm"]] < 0).any().any())

# === Step 4. Save merged dataset ===
data.to_csv("data/merged_dataset.csv", index=False)
print("Saved merged dataset -> data/merged_dataset.csv")
