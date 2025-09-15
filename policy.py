
import json
from typing import Dict, Any
import numpy as np
from joblib import load

class BCPolicy:
    def __init__(self, model_path: str, meta_path: str):
        self.model = load(model_path)
        with open(meta_path, "r", encoding="utf-8") as f:
            self.meta = json.load(f)
        self.features = self.meta["features"]
        self.actions = self.meta["actions"]
        self.lim = self.meta.get("limits", {"irrigate_max": 5.0, "drain_max": 3.0})

    def act(self, obs: Dict[str, float]) -> Dict[str, float]:
        X = np.array([[obs.get(k, 0.0) for k in self.features]], dtype=float)
        y = self.model.predict(X)[0]
        out = {}
        for j, a in enumerate(self.actions):
            v = float(y[j])
            if "irrigate" in a:
                v = max(0.0, min(v, float(self.lim.get("irrigate_max", 5.0))))
            else:
                v = max(0.0, min(v, float(self.lim.get("drain_max", 3.0))))
            out[a] = v
        return out
