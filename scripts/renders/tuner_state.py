#!/usr/bin/env python3
"""live-22 (2) — print the launch arguments that start the appearance tuner (DEBUG) in a given state, via the arguments
domain (`-appearanceTuning.v1 <data>`), for Simulator stills. Overrides: mode.key=value, e.g.
    tuner_state.py light.panel=frost50 light.saturation=0.4 dark.hairline=true
Defaults mirror AppearanceTuningValues.lightDefault / darkDefault."""
import json, sys
light = dict(palette="L2", fieldStep=1, shadowStrength=0.25, shadowRadius=12.5, hairline=True, hairlineWidth=0.5,
             hairlineOpacity=0.16, panel="today", tintOpacity=0.35, blur=1, saturation=1, glassControls=False,
             dimBehind=False, dimAmount=0.10)
dark = dict(light, palette="L2", fieldStep=0, shadowStrength=1, shadowRadius=12, hairline=False, hairlineOpacity=0.12)
PRESETS = {"today": (0.35, 1, 1, False), "frost35": (0.35, 2, 0.4, False), "frost50": (0.50, 2, 0.4, False),
           "frost65": (0.65, 2, 0.4, False), "frost50Glass": (0.50, 2, 0.4, True)}
state = {"light": light, "dark": dark}
for a in sys.argv[1:]:
    k, v = a.split("=", 1); mode, key = k.split(".")
    if key == "preset":
        state[mode]["panel"] = v
        if v in PRESETS: state[mode].update(zip(["tintOpacity", "blur", "saturation", "glassControls"], PRESETS[v]))
        if v == "liquidGlass": state[mode]["glassControls"] = True
        continue
    state[mode][key] = {"true": True, "false": False}.get(v, v if not v.replace(".", "").replace("-", "").isdigit() else float(v))
print("-AppearanceTuner YES -appearanceTuning.v1 <%s>" % json.dumps(state, separators=(",", ":")).encode().hex())
