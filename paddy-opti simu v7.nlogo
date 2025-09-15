extensions [ csv ]
breed [water-monitors water-monitor]

water-monitors-own [monitor-type]

globals [


  month-start-tick
  patch-area
  monthly-rainfall
  current-month
  rain-on?
  precipitation-total
  rain-chance
  rain-std-dev
  crop-stage
  stage-names
  stage-durations
  stage-start-tick
  target-water-levels
  lake-withdrawn
  drainage-on?
  total-drained
  drainage-stages ;; [3 7] for "Mid-Summer Drainage" and "Continuous Drainage"
  lake-level
  lake-capacity
  mixing-pool-level
  mixing-pool-capacity
  drainage-canal-level
  drainage-canal-capacity
   lake-area
  pool-area
  drain-area
  optimal-water-ranges ;; list of [min max] mm per stage
    rain_today_mm          ;; per-tick rainfall actually applied (mm)
  actual_loss_mm         ;; per-tick evap/seepage loss used (mm)

  ;; --- WATER QUALITY STATE (masses in mg) ---
  lake_N_mg lake_P_mg
  pool_N_mg pool_P_mg
  canal_N_mg canal_P_mg
  north_N_mg north_P_mg
  south_N_mg south_P_mg

  ;; cumulative export to lake (mg)
  cum_N_to_lake_mg
  cum_P_to_lake_mg

  ;; PARAMETERS (defaults set in setup)
  decay_rate_N
  decay_rate_P
  plant_uptake_N_mg_per_day
  plant_uptake_P_mg_per_day
  soil_retention_fraction  ;; 0–1 fraction of N/P that *stays* with soil when field drains

  ;; Stage-based fertiliser schedule (kg/ha for each of your 8 stages)
  N_kgHa_by_stage
  P_kgHa_by_stage

  ;;csv loggin

  log_on?
  log_filename
  prev_lake_withdrawn
  prev_cum_N_to_lake_mg
  prev_cum_P_to_lake_mg

    ;; ---- agent control & logging of applied actions ----
  control-mode                    ;; "rule" or "agent"

  ;; agent action requests (per tick, in mm)
  agent_irrigateN_mm
  agent_irrigateS_mm
  agent_drainN_mm
  agent_drainS_mm
  agent_pool_ratio               ;; [0,1] desired mixing-pool fill ratio

  ;; what ACTUALLY happened this tick (labels for BC training)
  last_irrigateN_mm
  last_irrigateS_mm
  last_drainN_mm
  last_drainS_mm

  policy-table   ;; holds rows from models/policy_table.csv

  log_root

]

patches-own [
  water-level
  is-lake?
  is-mixing-pool?
  is-irrigation-pump?
  is-north-field?
  is-south-field?
  is-canal?
  is-drainage-pump?
  crop-growth        ;; percentage from 0 to 100
  optimal-days       ;; days in optimal water range
]

to setup

  let lf log_filename
  let lr log_root
  let lo log_on?
  let cm control-mode

  clear-all
  reset-ticks

  ;; --- restore preserved values ---
  set log_filename lf
  set log_root lr
  set log_on? lo

  ;; restore control-mode (default to "rule" if invalid/empty)
  ifelse (is-string? cm and member? cm ["rule" "agent"])
  [ set control-mode cm ]
  [ set control-mode "rule" ]

  ;; ---------- world/layout ----------
  resize-world -25 25 -5 25
  set-patch-size 13
  setup-layout
  setup-indicators
  setup-labels
  setup-water-monitors

  ;; ---------- climate / calendar ----------
  set monthly-rainfall [40 40 40 60 120 140 130 90 80 60 50 40]
  set current-month 5
  set month-start-tick ticks
  set rain-on? true
  set precipitation-total 0
  set rain-chance 0.6
  set rain-std-dev 1

  ;; ---------- crop stages ----------
  set stage-names [
    "Land Preparation" "First Flooding" "Second Flooding" "Mid-Summer Drainage"
    "First Intermittent" "Third Flooding" "Second Intermittent" "Continuous Drainage"
  ]
  set patch-area 169
  set stage-durations [7 10 21 14 24 35 10 30]
  set stage-start-tick ticks
  set crop-stage 0
  set target-water-levels [15 35 25 0 25 25 25 0]

  ;; ---------- storages ----------
  set lake-withdrawn 0
  set lake-level 10000000
  set lake-capacity 100000000
  set mixing-pool-level 100000
  set mixing-pool-capacity 200000
  set drainage-canal-level 100000
  set drainage-canal-capacity 200000
  set lake-area count patches with [is-lake?]
  set pool-area count patches with [is-mixing-pool?]
  set drain-area count patches with [is-canal?]

    set rain_today_mm 0
  set actual_loss_mm 0
  set optimal-water-ranges [
    [10 20] [30 40] [20 30] [0 10] [20 30] [20 30] [20 30] [0 10]
  ]

  ;; ---------- water-quality params ----------
  set decay_rate_N 0
  set decay_rate_P 0
  set plant_uptake_N_mg_per_day 0
  set plant_uptake_P_mg_per_day 0
  set soil_retention_fraction 0.0

  set N_kgHa_by_stage [40 0 30 0 20 20 0 0]
  set P_kgHa_by_stage [20 0  0 0  0  0 0 0]

  ;; ---------- mass state init ----------
  set lake_N_mg 0
  set lake_P_mg 0
  set pool_N_mg 0
  set pool_P_mg 0
  set canal_N_mg 0
  set canal_P_mg 0
  set north_N_mg 0
  set north_P_mg 0
  set south_N_mg 0
  set south_P_mg 0
  set cum_N_to_lake_mg 0
  set cum_P_to_lake_mg 0

  ;; stage-0 fertiliser if any
  apply-fertiliser-for-current-stage

  ;; ---------- logging ----------
  if (not is-string? log_filename) or (log_filename = "") [
    set log_filename "rollout.csv"
  ]
  set prev_lake_withdrawn lake-withdrawn
  set prev_cum_N_to_lake_mg cum_N_to_lake_mg
  set prev_cum_P_to_lake_mg cum_P_to_lake_mg
  set log_on? true
  init-logging

  ;; ---------- agent defaults ----------
  set agent_irrigateN_mm 0
  set agent_irrigateS_mm 0
  set agent_drainN_mm    0
  set agent_drainS_mm    0
  set agent_pool_ratio   1.0

  ;; ---------- load policy if in agent mode ----------
  if control-mode = "agent" [
    ;; Ensure this path is correct *relative to your .nlogo file*,
    ;; or replace with an absolute path on your Mac.
    let policy-path "paddy_agent/models/policy_table.csv"
    ifelse file-exists? policy-path
    [ load-policy-table policy-path ]
    [ user-message (word
        "Agent mode selected but policy table is missing:\n"
        policy-path "\n\nPut policy_table.csv next to the model or fix the path in setup.")
      stop
    ]
  ]
end


to agent-step
  ;; ---------- sizes ----------
  let nPatchesN count patches with [is-north-field?]
  let nPatchesS count patches with [is-south-field?]

  ;; ---------- requested actions (mm) ----------
  let reqMmN agent_irrigateN_mm
  let reqMmS agent_irrigateS_mm
  let reqL_N (mm-to-litres reqMmN) * nPatchesN
  let reqL_S (mm-to-litres reqMmS) * nPatchesS
  let reqL_T reqL_N + reqL_S

  ;; ---------- canal-only pre-top-up (just enough for today) ----------
  if reqL_T > mixing-pool-level and drainage-canal-level > 0 [
    let shortfall reqL_T - mixing-pool-level
    let take min list shortfall drainage-canal-level
    let cN_c conc-canal-N
    let cP_c conc-canal-P
    set mixing-pool-level mixing-pool-level + take
    set drainage-canal-level drainage-canal-level - take
    set canal_N_mg max list 0 (canal_N_mg - take * cN_c)
    set canal_P_mg max list 0 (canal_P_mg - take * cP_c)
    set pool_N_mg  pool_N_mg  + take * cN_c
    set pool_P_mg  pool_P_mg  + take * cP_c
  ]

  ;; ---------- IRRIGATION (pool -> fields) ----------
  let scale 1
  if reqL_T > 0 [
    set scale min list 1 (safe-div mixing-pool-level reqL_T)
  ]
  let applMmN reqMmN * scale
  let applMmS reqMmS * scale
  let applL_N (mm-to-litres applMmN) * nPatchesN
  let applL_S (mm-to-litres applMmS) * nPatchesS
  let pumpedTotal applL_N + applL_S

  ;; concentrations before removal
  let cN_pool conc-pool-N
  let cP_pool conc-pool-P

  ask patches with [is-north-field?] [ set water-level water-level + applMmN ]
  ask patches with [is-south-field?] [ set water-level water-level + applMmS ]

  set mixing-pool-level mixing-pool-level - pumpedTotal
  set pool_N_mg max list 0 (pool_N_mg - pumpedTotal * cN_pool)
  set pool_P_mg max list 0 (pool_P_mg - pumpedTotal * cP_pool)
  set north_N_mg north_N_mg + applL_N * cN_pool
  set north_P_mg north_P_mg + applL_N * cP_pool
  set south_N_mg south_N_mg + applL_S * cN_pool
  set south_P_mg south_P_mg + applL_S * cP_pool

  set last_irrigateN_mm applMmN
  set last_irrigateS_mm applMmS

  ;; ---------- DRAINAGE (fields -> canal) ----------
  let nowN mean [water-level] of patches with [is-north-field?]
  let nowS mean [water-level] of patches with [is-south-field?]
  let mmDrainN min list agent_drainN_mm nowN
  let mmDrainS min list agent_drainS_mm nowS
  let LDrainN (mm-to-litres mmDrainN) * nPatchesN
  let LDrainS (mm-to-litres mmDrainS) * nPatchesS

  let cN_fieldN conc-north-N
  let cP_fieldN conc-north-P
  let cN_fieldS conc-south-N
  let cP_fieldS conc-south-P

  ask patches with [is-north-field?] [ set water-level max list 0 (water-level - mmDrainN) ]
  ask patches with [is-south-field?] [ set water-level max list 0 (water-level - mmDrainS) ]

  let leaveFrac (1 - soil_retention_fraction)
  set north_N_mg max list 0 (north_N_mg - LDrainN * cN_fieldN * leaveFrac)
  set north_P_mg max list 0 (north_P_mg - LDrainN * cP_fieldN * leaveFrac)
  set south_N_mg max list 0 (south_N_mg - LDrainS * cN_fieldS * leaveFrac)
  set south_P_mg max list 0 (south_P_mg - LDrainS * cP_fieldS * leaveFrac)
  set canal_N_mg canal_N_mg + (LDrainN * cN_fieldN + LDrainS * cN_fieldS) * leaveFrac
  set canal_P_mg canal_P_mg + (LDrainN * cP_fieldN + LDrainS * cP_fieldS) * leaveFrac

  set drainage-canal-level drainage-canal-level + LDrainN + LDrainS
  canal-overflow-to-lake

  set last_drainN_mm mmDrainN
  set last_drainS_mm mmDrainS

  ;; ---------- single refill to target ratio (canal first, lake last) ----------
  refill-mixing-pool-to-ratio
end




to setup-layout
  ask patches [
    set water-level 0
    set is-lake? false
    set is-mixing-pool? false
    set is-irrigation-pump? false
    set is-north-field? false
    set is-south-field? false
    set is-canal? false
    set is-drainage-pump? false
      set crop-growth 0
  set optimal-days 0

    let x pxcor
    let y pycor

    if y >= 22 and y <= 24 [
      set is-lake? true
      set pcolor blue + (random-float 0.5)
    ]
    if y >= 16 and y <= 20 and x >= -10 and x <= 10 [
      set is-north-field? true
      set pcolor green + (random-float 0.6 - 0.3)
    ]
    if y >= 12 and y <= 14 [
      if x >= -24 and x <= -18 [
        set is-irrigation-pump? true
        set pcolor sky + 2
      ]
      if x >= -15 and x <= -9 [
        set is-mixing-pool? true
        set pcolor cyan + (random-float 0.5)
      ]
      if x >= -5 and x <= 19 [
        set is-canal? true
        set pcolor blue + (random-float 0.6)
      ]
      if x >= 21 and x <= 25 [
        set is-drainage-pump? true
        set pcolor violet + 1
      ]
    ]
    if y >= 7 and y <= 11 and x >= -10 and x <= 10 [
      set is-south-field? true
      set pcolor green - 1 + (random-float 0.6)
    ]
    if member? y [15 12 6] [
      set pcolor black
    ]
  ]
end

to setup-labels
  create-turtles 1 [
    setxy 0 23
    set shape "square"
    set size 0
    set label "Lake"
    set label-color white
  ]
  create-turtles 1 [
    setxy 0 18
    set shape "square"
    set size 0
    set label "North Paddy Field"
    set label-color white
  ]
  create-turtles 1 [
    setxy 0 9
    set shape "square"
    set size 0
    set label "South Paddy Field"
    set label-color white
  ]
  create-turtles 1 [
    setxy -18 13
    set shape "square"
    set size 0
    set label "Irrigation Pump"
    set label-color white
  ]
  create-turtles 1 [
    setxy -10 13
    set shape "square"
    set size 0
    set label "Mixing Pool"
    set label-color white
  ]
  create-turtles 1 [
    setxy 7 13
    set shape "square"
    set size 0
    set label "Main Drainage Canal"
    set label-color white
  ]
  create-turtles 1 [
    setxy 26 13
    set shape "square"
    set size 0
    set label "Drainage Pump"
    set label-color white
  ]


end

to setup-indicators
;  ;create-turtles 1 [
;    setxy -22 16
;    set shape "square"
;    set size 1.5
;    set color red
;    set label "Pump OFF"
;    set label-color white
;  ]
;  create-turtles 1 [
;    setxy 22 7
;    set shape "square"
;    set size 1.5
;    set color red
;    set label "Drain OFF"
;    set label-color white
;;  ]
  create-turtles 1 [
    setxy 22 12
    set shape "square"
    set size 1.5
    set color green
    set label "WQ: 100%"
    set label-color white
  ]
  create-turtles 1 [
    setxy 22 10
    set shape "square"
    set size 1.5
    set color yellow
    set label "Waste: 0L"
    set label-color black
  ]
end

to setup-water-monitors
  create-water-monitors 1 [
    setxy 14 18
    set shape "square"
    set size 0
    set label "North: 0 mm"
    set color green
    set label-color white
    set monitor-type "north"
  ]
  create-water-monitors 1 [
    setxy 14 9
    set shape "square"
    set size 0
    set label "South: 0 mm"
    set color green - 1
    set label-color white
    set monitor-type "south"
  ]
  create-water-monitors 1 [
    setxy 0 26
    set shape "square"
    set size 0
    set label "Stage: Land Preparation"
    set color white
    set label-color white
    set monitor-type "stage"
  ]


  create-water-monitors 1 [
  setxy 0 29
  set shape "square"
  set size 1
  set label-color white
  set label (word "Total Pumped: " lake-withdrawn " L")
]
      create-water-monitors 1 [
    setxy -16 4
    set shape "square"
    set size 0
    set label-color white
    set monitor-type "lake"
  ]

  create-water-monitors 1 [
    setxy -16 3
    set shape "square"
    set size 0
    set label-color white
    set monitor-type "mix"
  ]

  create-water-monitors 1 [
    setxy -16 2
    set shape "square"
    set size 0
    set label-color white
    set monitor-type "drain"
  ]

  create-water-monitors 1 [
  setxy 14 26
  set shape "square"
  set size 0
  set label-color white
  set monitor-type "growth"
]
    create-water-monitors 1 [
    setxy 20 4
    set shape "square"  set size 0  set label-color white
    set monitor-type "wq-pool"
  ]
  create-water-monitors 1 [
    setxy 20 3
    set shape "square"  set size 0  set label-color white
    set monitor-type "wq-canal"
  ]
  create-water-monitors 1 [
    setxy 20 2
    set shape "square"  set size 0  set label-color white
    set monitor-type "wq-lake"
  ]


end

to update-water-monitors
  ask water-monitors [
    if monitor-type = "north" [
      set label (word "North: " precision mean [water-level] of patches with [is-north-field?] 1 " mm")
    ]
    if monitor-type = "south" [
      set label (word "South: " precision mean [water-level] of patches with [is-south-field?] 1 " mm")
    ]
    if monitor-type = "stage" [
      set label (word "Stage: " item crop-stage stage-names)
    ]
    if not member? monitor-type ["north" "south" "stage"] [  ;; handles total pumped
      set label (word "Total Pumped: " precision lake-withdrawn 1 " L")
    ]

    if monitor-type = "lake" [
  set label (word "Lake Level: " precision (litres-to-mm-lake lake-level) 1 " mm")
]
if monitor-type = "mix" [
  set label (word "Mixing Pool: " precision (litres-to-mm-pool mixing-pool-level) 1 " mm")
]
if monitor-type = "drain" [
  set label (word "Drainage Canal: " precision (litres-to-mm-drain drainage-canal-level) 1 " mm")
]

if monitor-type = "growth" [
  let avg-growth mean [crop-growth] of patches with [is-north-field? or is-south-field?]
  set label (word "Avg Growth: " precision avg-growth 1 " %")
]
    if monitor-type = "wq-pool" [
      set label (word "Pool WQ: "
        precision conc-pool-N 2 " N mg/L, "
        precision conc-pool-P 2 " P mg/L")
    ]
    if monitor-type = "wq-canal" [
      set label (word "Canal WQ: "
        precision conc-canal-N 2 " N mg/L, "
        precision conc-canal-P 2 " P mg/L")
    ]
    if monitor-type = "wq-lake" [
      set label (word "Lake WQ: "
        precision conc-lake-N 2 " N mg/L, "
        precision conc-lake-P 2 " P mg/L")
    ]




  ]

end

to-report mm-to-litres [mm]
  report mm * patch-area
end

to-report litres-to-mm [litres]
  report litres / patch-area
end

to-report safe-div [num den]
  report ifelse-value (den = 0) [0] [num / den]
end

to-report litres-to-mm-lake [L]
  report safe-div L (lake-area * patch-area)
end

to-report litres-to-mm-pool [L]
  report safe-div L (pool-area * patch-area)
end

to-report litres-to-mm-drain [L]
  report safe-div L (drain-area * patch-area)
end

to set-action [iN iS dN dS p]
  set agent_irrigateN_mm max list 0 (min list 5 iN)
  set agent_irrigateS_mm max list 0 (min list 5 iS)
  set agent_drainN_mm    max list 0 (min list 3 dN)
  set agent_drainS_mm    max list 0 (min list 3 dS)
  set agent_pool_ratio   max list 0 (min list 1 p)
end

to load-policy-table [path]
  if not file-exists? path [
    user-message (word "Policy table not found: " path)
    stop
  ]

  let rows csv:from-file path
  if empty? rows [
    user-message "Policy table is empty."
    stop
  ]

  ;; drop header row if present
  if is-string? item 0 first rows [
    let h item 0 first rows
    if (h = "stage") or (h = "Stage") or (h = "STAGE") [
      set rows but-first rows
    ]
  ]

  ;; coerce strings to numbers
  set policy-table map
  [ row ->
      map [ x -> ifelse-value (is-string? x) [ read-from-string x ] [ x ] ]
          row
  ]
  rows

  ;; <-- ADD THIS LINE
  print (word "Loaded policy table with " length policy-table " rows.")
end





to go
  ;; reset per-tick action labels (so zeros are written when nothing happens)
  set last_irrigateN_mm 0
  set last_irrigateS_mm 0
  set last_drainN_mm    0
  set last_drainS_mm    0

    set rain_today_mm 0       ;; reset for this tick
  set actual_loss_mm 0      ;; will be set in natural-water-loss


advance-month
  apply-rainfall

  if control-mode = "rule" [
    field-drainage
    auto-irrigation
  ]

  if control-mode = "agent" [
    agent-policy-decide
    agent-step
  ]

  natural-water-loss
  quality-processes
  update-crop-stage

  update-crop-growth
  update-paddy-colors
  update-water-monitors
  log-step
  tick
end


to-report days-in-month [m]            ;; m = 1..12
  report item (m - 1) [31 28 31 30 31 30 31 31 30 31 30 31]
end

to-report day-in-stage
  report ticks - stage-start-tick
end

to-report norm-day-in-stage
  report safe-div (ticks - stage-start-tick) (item crop-stage stage-durations)
end

to-report obs-vector
  let north_mm mean [water-level] of patches with [is-north-field?]
  let south_mm mean [water-level] of patches with [is-south-field?]
  report (list
    crop-stage
    norm-day-in-stage
    north_mm south_mm
    (item crop-stage target-water-levels)
    (safe-div mixing-pool-level     mixing-pool-capacity)
    (safe-div drainage-canal-level  drainage-canal-capacity)
    (safe-div lake-level            lake-capacity)
    conc-pool-N conc-pool-P
    conc-canal-N conc-canal-P
    rain_today_mm
    actual_loss_mm
  )
end


to-report month-dist [m1 m2]
  let d abs (m1 - m2)
  report min list d (12 - d)   ;; circular month distance
end
to-report nearest-policy-row [stage mo defN defS canal pool]
  if (not is-list? policy-table) or (length policy-table = 0) [ report nobody ]

  ;; first filter by exact stage & month
  let candidates filter [ row -> (item 0 row = stage) and (item 1 row = mo) ] policy-table
  if empty? candidates [ report nobody ]

  ;; then the original distance on the much smaller subset
  let best nobody
  let bestd 1e9
  foreach candidates [[row] ->
    let st2     item 0 row
    let mo2     item 1 row
    let dN2     item 2 row
    let dS2     item 3 row
    let canal2  item 4 row
    let pool2   item 5 row

    let w_stage 5
    let w_month 2
    let w_def   1
    let w_canal 0.05
    let w_pool  1

    let d_stage (ifelse-value (stage = st2) [0] [1])
    let d_m     0                          ;; filtered exact month, so 0
    let d_defN  defN - dN2
    let d_defS  defS - dS2
    let d_canal canal - canal2
    let d_pool  pool - pool2

    let d ( w_stage * d_stage
          + w_month * (d_m ^ 2)
          + w_def * ((d_defN ^ 2) + (d_defS ^ 2))
          + w_canal * (d_canal ^ 2)
          + w_pool * (d_pool ^ 2) )

    if d < bestd [ set bestd d  set best row ]
  ]
  report best
end









to advance-month
  if ticks - month-start-tick >= days-in-month current-month [
    set current-month current-month + 1
    if current-month > 12 [ set current-month 1 ]
    set month-start-tick ticks
  ]
end


to apply-rainfall
  ;; default = no rain this tick
  set rain_today_mm 0

  if rain-on? and (random-float 1.0 < rain-chance) [
    let month-mm   item (current-month - 1) monthly-rainfall
    let daily-mean month-mm / days-in-month current-month
    let rain-amount max list 0 (random-normal daily-mean rain-std-dev)

    set rain_today_mm rain-amount

    ask patches with [is-north-field? or is-south-field?] [
      set water-level water-level + rain-amount
    ]
    set precipitation-total precipitation-total + rain-amount
    ;; NOTE: no N/P mass added from rain
  ]
end


to update-crop-stage
  let duration item crop-stage stage-durations
  if ticks - stage-start-tick >= duration [
    set crop-stage crop-stage + 1
    if crop-stage >= length stage-durations [
      set crop-stage length stage-durations - 1
    ]
    set stage-start-tick ticks
    print (word "Advancing to stage: " item crop-stage stage-names)

    ;; NEW: apply stage doses (if any)
    apply-fertiliser-for-current-stage
  ]
end


to canal-overflow-to-lake
  let overflow max list 0 (drainage-canal-level - drainage-canal-capacity)
  if overflow > 0 [
    let lake-room max list 0 (lake-capacity - lake-level)
    let to-lake min list overflow lake-room

    let cN_canal conc-canal-N
    let cP_canal conc-canal-P

    ;; volumes
    set drainage-canal-level drainage-canal-level - to-lake
    set lake-level lake-level + to-lake

    ;; masses
    let moveN to-lake * cN_canal
    let moveP to-lake * cP_canal
    set canal_N_mg max list 0 (canal_N_mg - moveN)
    set canal_P_mg max list 0 (canal_P_mg - moveP)
    set lake_N_mg lake_N_mg + moveN
    set lake_P_mg lake_P_mg + moveP

    ;; accountability
    set cum_N_to_lake_mg cum_N_to_lake_mg + moveN
    set cum_P_to_lake_mg cum_P_to_lake_mg + moveP
  ]
end



to update-paddy-colors
  let stage-color-map [
    31    ;; 0: Land Preparation (brown)
    75    ;; 1: First Flooding (light bluey)
    75    ;; 2: Second Flooding (light brownish-green)
    35    ;; 3: Mid-Summer Drainage (dull green)
    65    ;; 4: First Intermittent (green)
    65    ;; 5: Third Flooding (bright green)
    yellow    ;; 6: Second Intermittent (green-blue)
    yellow   ;; 7: Continuous Drainage (yellow)
  ]

  let base-color item crop-stage stage-color-map

  ask patches with [is-north-field? or is-south-field?] [
    set pcolor base-color + random-float 0.6 - 0.3
  ]
end

to natural-water-loss
  let stage-loss-multipliers [0.5 0.8 1.0 1.2 1.0 1.1 1.3 1.0]
  let dry-factor  ifelse-value (member? current-month [1 2 3 12]) [1.3] [1.0]
  let stage-factor item crop-stage stage-loss-multipliers

  let actual-loss base-loss * stage-factor * dry-factor
  set actual_loss_mm actual-loss

  ask patches with [is-north-field? or is-south-field?] [
    set water-level max list 0 (water-level - actual-loss)
  ]
end


to auto-irrigation

  refill-mixing-pool
  let target item crop-stage target-water-levels
  let irrigation-rate 5

  ;; Volumes before irrigation
  let vN_before north-field-volume-litres
  let vS_before south-field-volume-litres

  ;; Pool concentrations before removal
  let cN_pool conc-pool-N
  let cP_pool conc-pool-P

  ;; Your existing per-patch top-up from pool
  ask patches with [is-north-field? or is-south-field?] [
    if water-level < target [
      let mm-needed min list (target - water-level) irrigation-rate
      let litres-needed mm-to-litres mm-needed
      if mixing-pool-level >= litres-needed [
        set water-level water-level + mm-needed
        set mixing-pool-level mixing-pool-level - litres-needed
      ]
    ]
  ]

  ;; Pumped volumes to each field (L)
  let vN_after north-field-volume-litres
  let vS_after south-field-volume-litres
  let pumpedN max list 0 (vN_after - vN_before)
  let pumpedS max list 0 (vS_after - vS_before)
  let pumpedTotal pumpedN + pumpedS

  ;; Move mass Pool -> Fields (pre-pump concentration)
  if pumpedTotal > 0 [
    set pool_N_mg max list 0 (pool_N_mg - pumpedTotal * cN_pool)
    set pool_P_mg max list 0 (pool_P_mg - pumpedTotal * cP_pool)

    set north_N_mg north_N_mg + pumpedN * cN_pool
    set north_P_mg north_P_mg + pumpedN * cP_pool
    set south_N_mg south_N_mg + pumpedS * cN_pool
    set south_P_mg south_P_mg + pumpedS * cP_pool
  ]
  ;; --- Log rule's applied irrigation (mm per field) ---
  let north_area ((count patches with [is-north-field?]) * patch-area)
  let south_area ((count patches with [is-south-field?]) * patch-area)
  if pumpedN > 0 [ set last_irrigateN_mm safe-div pumpedN north_area ]
  if pumpedS > 0 [ set last_irrigateS_mm safe-div pumpedS south_area ]

  ;; Refill pool (keeps your strict priority canal->pool else lake->pool)
  refill-mixing-pool
end

to agent-policy-decide
  let stage crop-stage
  let mo    current-month
  let tgt   item stage target-water-levels

  ;; current state
  let north_mm mean [water-level] of patches with [is-north-field?]
  let south_mm mean [water-level] of patches with [is-south-field?]
  let defN max list 0 (tgt - north_mm)
  let defS max list 0 (tgt - south_mm)
  let excessN max list 0 (north_mm - tgt)
  let excessS max list 0 (south_mm - tgt)

  let canal_mm   litres-to-mm-drain drainage-canal-level
  let pool_ratio safe-div mixing-pool-level mixing-pool-capacity

  ;; nearest row (stage & month exact match inside the reporter you added)
  let row nearest-policy-row stage mo defN defS canal_mm pool_ratio

  ;; defaults if nothing found
  let iN_raw 0
  let iS_raw 0
  let dN_raw 0
  let dS_raw 0
  if row != nobody [
    set iN_raw item 6 row
    set iS_raw item 7 row
    set dN_raw item 8 row
    set dS_raw item 9 row
  ]

  ;; --- irrigation: clamp to remaining deficit (deadband 1 mm) ---
  let iN (ifelse-value (defN < 1) [0] [min list iN_raw defN])
  let iS (ifelse-value (defS < 1) [0] [min list iS_raw defS])

  ;; --- drainage policy ---
  let drainStages [3 7]
  let maxDrain 3
  let floorDrain 0.5

  ;; pre-compute bounded predictions
  let predN (min list maxDrain dN_raw)
  let predS (min list maxDrain dS_raw)

  let dN (
    ifelse-value (defN > 0) [
      0
    ] [
      ifelse-value (member? stage drainStages) [
        ifelse-value (predN >= floorDrain)
          [ predN ]
          [ min list maxDrain excessN ]
      ] [
        min list maxDrain excessN
      ]
    ]
  )

  let dS (
    ifelse-value (defS > 0) [
      0
    ] [
      ifelse-value (member? stage drainStages) [
        ifelse-value (predS >= floorDrain)
          [ predS ]
          [ min list maxDrain excessS ]
      ] [
        min list maxDrain excessS
      ]
    ]
  )


  ;; --- minimal pool ratio for today's irrigation (+10% buffer) ---
  let nPatchesN count patches with [is-north-field?]
  let nPatchesS count patches with [is-south-field?]
  let needL ((mm-to-litres iN) * nPatchesN + (mm-to-litres iS) * nPatchesS)
  let wantL max list mixing-pool-level (needL * 1.10)
  let desired_ratio min list 1 (safe-div wantL mixing-pool-capacity)

  set-action iN iS dN dS desired_ratio
end






to field-drainage
  let max-drain-mm 3

  ;; Field volumes & concentrations BEFORE drainage
  let vN0 north-field-volume-litres
  let vS0 south-field-volume-litres
  let cN_fieldN conc-north-N
  let cP_fieldN conc-north-P
  let cN_fieldS conc-south-N
  let cP_fieldS conc-south-P

  ;; Hydraulics: your current drain rule
  ask patches with [is-north-field? or is-south-field?] [
    let target item crop-stage target-water-levels
    let excess max list 0 (water-level - target)
    if excess > 0 or member? crop-stage [3 7] [
      let drain-mm min list excess max-drain-mm
      set water-level water-level - drain-mm
    ]
  ]

  ;; Volumes AFTER drainage
  let vN1 north-field-volume-litres
  let vS1 south-field-volume-litres
  let drainedN max list 0 (vN0 - vN1)
  let drainedS max list 0 (vS0 - vS1)
  let drainedTotal drainedN + drainedS

  ;; Mass with drained water (apply soil retention)
  if drainedTotal > 0 [
    let leaveFrac (1 - soil_retention_fraction)
    let moveN_N (drainedN * cN_fieldN * leaveFrac)
    let moveN_P (drainedN * cP_fieldN * leaveFrac)
    let moveS_N (drainedS * cN_fieldS * leaveFrac)
    let moveS_P (drainedS * cP_fieldS * leaveFrac)

    set north_N_mg max list 0 (north_N_mg - moveN_N)
    set north_P_mg max list 0 (north_P_mg - moveN_P)
    set south_N_mg max list 0 (south_N_mg - moveS_N)
    set south_P_mg max list 0 (south_P_mg - moveS_P)

    set canal_N_mg canal_N_mg + moveN_N + moveS_N
    set canal_P_mg canal_P_mg + moveN_P + moveS_P

    ;; Add drained volume to canal
    set drainage-canal-level drainage-canal-level + drainedTotal
  ]
  ;; --- Log rule's applied drainage (mm per field) ---
  let north_area2 ((count patches with [is-north-field?]) * patch-area)
  let south_area2 ((count patches with [is-south-field?]) * patch-area)
  if drainedN > 0 [ set last_drainN_mm safe-div drainedN north_area2 ]
  if drainedS > 0 [ set last_drainS_mm safe-div drainedS south_area2 ]

  ;; Overflow (will move mass too)
  canal-overflow-to-lake
end



to refill-mixing-pool
  let cap  mixing-pool-capacity
  let need max list 0 (cap - mixing-pool-level)
  if need <= 0 [ stop ]

  ;; 1) Canal first
  let takeC min list need drainage-canal-level
  if takeC > 0 [
    let cN_c conc-canal-N
    let cP_c conc-canal-P
    set mixing-pool-level mixing-pool-level + takeC
    set drainage-canal-level drainage-canal-level - takeC
    set canal_N_mg max list 0 (canal_N_mg - takeC * cN_c)
    set canal_P_mg max list 0 (canal_P_mg - takeC * cP_c)
    set pool_N_mg  pool_N_mg  + takeC * cN_c
    set pool_P_mg  pool_P_mg  + takeC * cP_c
    set need need - takeC
  ]

  ;; 2) Lake for the remainder
  if need > 0 [
    let takeL min list need lake-level
    if takeL > 0 [
      let cN_l conc-lake-N
      let cP_l conc-lake-P
      set mixing-pool-level mixing-pool-level + takeL
      set lake-level lake-level - takeL
      set lake-withdrawn lake-withdrawn + takeL
      set lake_N_mg max list 0 (lake_N_mg - takeL * cN_l)
      set lake_P_mg max list 0 (lake_P_mg - takeL * cP_l)
      set pool_N_mg  pool_N_mg  + takeL * cN_l
      set pool_P_mg  pool_P_mg  + takeL * cP_l
    ]
  ]

  ;; tiny numerical guard: if we overshoot cap by eps, scale masses
  if mixing-pool-level > cap [
    let factor safe-div cap mixing-pool-level
    set mixing-pool-level cap
    set pool_N_mg pool_N_mg * factor
    set pool_P_mg pool_P_mg * factor
  ]
end





to update-crop-growth
  let opt-range item crop-stage optimal-water-ranges
  let min-opt first opt-range
  let max-opt last opt-range

  ask patches with [is-north-field? or is-south-field?] [
    ifelse water-level >= min-opt and water-level <= max-opt [
      ;; In optimal range
      set crop-growth min list 100 (crop-growth + 0.5)
      set optimal-days optimal-days + 1
    ] [
      ;; Outside optimal range
      set crop-growth max list 0 (crop-growth - 0.2)
    ]
  ]
end

to apply-fertiliser-for-current-stage
  ;; Adds N/P to BOTH fields' surface water mass when a stage begins (v1 simple).
  let doseN_kgHa item crop-stage N_kgHa_by_stage
  let doseP_kgHa item crop-stage P_kgHa_by_stage
  if (doseN_kgHa = 0 and doseP_kgHa = 0) [ stop ]

  let north_patches count patches with [is-north-field?]
  let south_patches count patches with [is-south-field?]
  let area_north_m2 (north_patches * patch-area)
  let area_south_m2 (south_patches * patch-area)

  ;; kg/ha -> mg, given patch-area acts as m^2 per patch in your conversion
  ;; mg = kg_per_ha * area_m2 * 100   (1e6 mg/kg / 1e4 m2/ha = 100)
  let addN_north_mg doseN_kgHa * area_north_m2 * 100
  let addN_south_mg doseN_kgHa * area_south_m2 * 100
  let addP_north_mg doseP_kgHa * area_north_m2 * 100
  let addP_south_mg doseP_kgHa * area_south_m2 * 100

  set north_N_mg north_N_mg + addN_north_mg
  set south_N_mg south_N_mg + addN_south_mg
  set north_P_mg north_P_mg + addP_north_mg
  set south_P_mg south_P_mg + addP_south_mg
end


;; -------- Field volumes (litres) --------
to-report north-field-volume-litres
  report sum [ mm-to-litres water-level ] of patches with [is-north-field?]
end

to-report south-field-volume-litres
  report sum [ mm-to-litres water-level ] of patches with [is-south-field?]
end

;; -------- Concentrations (mg/L) with divide-by-zero guard --------
to-report conc-lake-N    report safe-div lake_N_mg  lake-level           end
to-report conc-lake-P    report safe-div lake_P_mg  lake-level           end
to-report conc-pool-N    report safe-div pool_N_mg  mixing-pool-level    end
to-report conc-pool-P    report safe-div pool_P_mg  mixing-pool-level    end
to-report conc-canal-N   report safe-div canal_N_mg drainage-canal-level end
to-report conc-canal-P   report safe-div canal_P_mg drainage-canal-level end

to-report conc-north-N
  let v north-field-volume-litres
  report safe-div north_N_mg v
end
to-report conc-north-P
  let v north-field-volume-litres
  report safe-div north_P_mg v
end

to-report conc-south-N
  let v south-field-volume-litres
  report safe-div south_N_mg v
end
to-report conc-south-P
  let v south-field-volume-litres
  report safe-div south_P_mg v
end

to quality-processes
  ;; first-order decay (per day)
  if decay_rate_N > 0 [
    set lake_N_mg  max list 0 (lake_N_mg  * (1 - decay_rate_N))
    set pool_N_mg  max list 0 (pool_N_mg  * (1 - decay_rate_N))
    set canal_N_mg max list 0 (canal_N_mg * (1 - decay_rate_N))
    set north_N_mg max list 0 (north_N_mg * (1 - decay_rate_N))
    set south_N_mg max list 0 (south_N_mg * (1 - decay_rate_N))
  ]
  if decay_rate_P > 0 [
    set lake_P_mg  max list 0 (lake_P_mg  * (1 - decay_rate_P))
    set pool_P_mg  max list 0 (pool_P_mg  * (1 - decay_rate_P))
    set canal_P_mg max list 0 (canal_P_mg * (1 - decay_rate_P))
    set north_P_mg max list 0 (north_P_mg * (1 - decay_rate_P))
    set south_P_mg max list 0 (south_P_mg * (1 - decay_rate_P))
  ]

  ;; simple constant plant uptake (off by default)
  if plant_uptake_N_mg_per_day > 0 [
    set north_N_mg max list 0 (north_N_mg - plant_uptake_N_mg_per_day)
    set south_N_mg max list 0 (south_N_mg - plant_uptake_N_mg_per_day)
  ]
  if plant_uptake_P_mg_per_day > 0 [
    set north_P_mg max list 0 (north_P_mg - plant_uptake_P_mg_per_day)
    set south_P_mg max list 0 (south_P_mg - plant_uptake_P_mg_per_day)
  ]
end




to init-logging
  if not log_on? [ stop ]
  if (not is-string? log_filename) or (log_filename = "") [
    set log_filename "rollout.csv"
  ]
  carefully [
    file-close-all
    if file-exists? log_filename [ file-delete log_filename ]
    file-open log_filename
    file-print "tick,stage,month,north_mm,south_mm,pool_mm,canal_mm,lake_mm,poolN_mgL,poolP_mgL,canalN_mgL,canalP_mgL,lakeN_mgL,lakeP_mgL,target_mm,defN_mm,defS_mm,delta_lake_L,delta_N_to_lake_mg,delta_P_to_lake_mg,irrigateN_mm,irrigateS_mm,drainN_mm,drainS_mm,pool_ratio,control_mode,rain_today_mm,actual_loss_mm,growth_avg_pct,growthN_pct,growthS_pct"



  ] [
    user-message (word "LOGGING ERROR for " log_filename " -> " error-message)
    stop
  ]
end




to refill-mixing-pool-to-ratio
  let targetVol agent_pool_ratio * mixing-pool-capacity
  let need max list 0 (targetVol - mixing-pool-level)
  if need <= 0 [ stop ]

  ;; 1) Canal first
  let takeC min list need drainage-canal-level
  if takeC > 0 [
    let cN_c conc-canal-N
    let cP_c conc-canal-P
    set mixing-pool-level mixing-pool-level + takeC
    set drainage-canal-level drainage-canal-level - takeC
    set canal_N_mg max list 0 (canal_N_mg - takeC * cN_c)
    set canal_P_mg max list 0 (canal_P_mg - takeC * cP_c)
    set pool_N_mg  pool_N_mg  + takeC * cN_c
    set pool_P_mg  pool_P_mg  + takeC * cP_c
    set need need - takeC
  ]

  ;; 2) Lake for the remainder
  if need > 0 [
    let takeL min list need lake-level
    if takeL > 0 [
      let cN_l conc-lake-N
      let cP_l conc-lake-P
      set mixing-pool-level mixing-pool-level + takeL
      set lake-level lake-level - takeL
      set lake-withdrawn lake-withdrawn + takeL
      set lake_N_mg max list 0 (lake_N_mg - takeL * cN_l)
      set lake_P_mg max list 0 (lake_P_mg - takeL * cP_l)
      set pool_N_mg  pool_N_mg  + takeL * cN_l
      set pool_P_mg  pool_P_mg  + takeL * cP_l
    ]
  ]

  ;; numerical guard to hit targetVol exactly without mass error
  if mixing-pool-level > targetVol [
    let factor safe-div targetVol mixing-pool-level
    set mixing-pool-level targetVol
    set pool_N_mg pool_N_mg * factor
    set pool_P_mg pool_P_mg * factor
  ]
end



to log-step
  if not log_on? [ stop ]

  ;; water levels (mm)
  let north_mm mean [water-level] of patches with [is-north-field?]
  let south_mm mean [water-level] of patches with [is-south-field?]
  let pool_mm  litres-to-mm-pool mixing-pool-level
  let canal_mm litres-to-mm-drain drainage-canal-level
  let lake_mm  litres-to-mm-lake lake-level

  ;; water quality (mg/L)
  let poolN conc-pool-N
  let poolP conc-pool-P
  let canalN conc-canal-N
  let canalP conc-canal-P
  let lakeN conc-lake-N
  let lakeP conc-lake-P

  ;; targets & deficits
  let tgt item crop-stage target-water-levels
  let defN max list 0 (tgt - north_mm)
  let defS max list 0 (tgt - south_mm)

  ;; deltas for reward building later
  let dLake   (lake-withdrawn - prev_lake_withdrawn)
  let dNlake  (cum_N_to_lake_mg - prev_cum_N_to_lake_mg)
  let dPlake  (cum_P_to_lake_mg - prev_cum_P_to_lake_mg)

  let pool_ratio (safe-div mixing-pool-level mixing-pool-capacity)

  let growthN_pct mean [crop-growth] of patches with [is-north-field?]
let growthS_pct mean [crop-growth] of patches with [is-south-field?]
let growth_avg_pct mean [crop-growth] of patches with [is-north-field? or is-south-field?]

;; CSV: make stage 1..8 (config expects this)
let stage_out (crop-stage + 1)


  ;; single CSV row (matches your header)
file-print (word
  ticks "," stage_out "," current-month ","
  north_mm "," south_mm "," pool_mm "," canal_mm "," lake_mm ","
  poolN "," poolP "," canalN "," canalP "," lakeN "," lakeP ","
  tgt "," defN "," defS ","
  dLake "," dNlake "," dPlake ","
  last_irrigateN_mm "," last_irrigateS_mm ","
  last_drainN_mm "," last_drainS_mm ","
  pool_ratio "," control-mode ","
  rain_today_mm "," actual_loss_mm ","
  growth_avg_pct "," growthN_pct "," growthS_pct
)




  ;; update “previous” counters
  set prev_lake_withdrawn lake-withdrawn
  set prev_cum_N_to_lake_mg cum_N_to_lake_mg
  set prev_cum_P_to_lake_mg cum_P_to_lake_mg
end


to run-episodes [n root]
  set log_root root
  let base-seed 12345
  let i 0
  while [i < n] [
    let desired-mode control-mode
;    let prefix ifelse-value (desired-mode = "agent") ["agent_ep"] ["rule_ep"]
    let prefix ifelse-value (desired-mode = "agent") ["eval_agent_ep"] ["eval_rule_ep"]
   set log_filename (word root "/" prefix i ".csv")




    random-seed (base-seed + i)

    ;; IMPORTANT: set the mode before setup so setup loads policy_table
    set control-mode desired-mode
    setup

    ;; keep the chosen mode
    set control-mode desired-mode

    repeat sum stage-durations [ go ]
    file-close-all
    set i i + 1
  ]
end

to run-paired-episodes [n root]
  set log_root (word root "/paired")
  let base-seed 12345
  let i 0
  while [i < n] [

    ;; RULE RUN
    random-seed (base-seed + i)
    set control-mode "rule"
    set log_filename (word log_root "/rule_ep" i ".csv")
    setup
    repeat sum stage-durations [ go ]
    file-close-all

    ;; AGENT RUN (same seed)
    random-seed (base-seed + i)
    set control-mode "agent"
    set log_filename (word log_root "/agent_ep" i ".csv")
    setup
    repeat sum stage-durations [ go ]
    file-close-all

    set i i + 1
  ]
end
@#$#@#$#@
GRAPHICS-WINDOW
210
10
881
422
-1
-1
13.0
1
10
1
1
1
0
1
1
1
-25
25
-5
25
0
0
1
ticks
30.0

BUTTON
97
111
163
144
NIL
setup\n
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
98
224
161
257
NIL
go\n
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

MONITOR
932
50
1058
95
NIL
precipitation-total
17
1
11

SLIDER
236
470
408
503
base-loss
base-loss
0.1
5
2.9
0.1
1
NIL
HORIZONTAL

@#$#@#$#@
## WHAT IS IT?

(a general understanding of what the model is trying to show or explain)

## HOW IT WORKS

(what rules the agents use to create the overall behavior of the model)

## HOW TO USE IT

(how to use the model, including a description of each of the items in the Interface tab)

## THINGS TO NOTICE

(suggested things for the user to notice while running the model)

## THINGS TO TRY

(suggested things for the user to try to do (move sliders, switches, etc.) with the model)

## EXTENDING THE MODEL

(suggested things to add or change in the Code tab to make the model more complicated, detailed, accurate, etc.)

## NETLOGO FEATURES

(interesting or unusual features of NetLogo that the model uses, particularly in the Code tab; or where workarounds were needed for missing features)

## RELATED MODELS

(models in the NetLogo Models Library and elsewhere which are of related interest)

## CREDITS AND REFERENCES

(a reference to the model's URL on the web if it has one, as well as any other necessary credits, citations, and links)
@#$#@#$#@
default
true
0
Polygon -7500403 true true 150 5 40 250 150 205 260 250

airplane
true
0
Polygon -7500403 true true 150 0 135 15 120 60 120 105 15 165 15 195 120 180 135 240 105 270 120 285 150 270 180 285 210 270 165 240 180 180 285 195 285 165 180 105 180 60 165 15

arrow
true
0
Polygon -7500403 true true 150 0 0 150 105 150 105 293 195 293 195 150 300 150

box
false
0
Polygon -7500403 true true 150 285 285 225 285 75 150 135
Polygon -7500403 true true 150 135 15 75 150 15 285 75
Polygon -7500403 true true 15 75 15 225 150 285 150 135
Line -16777216 false 150 285 150 135
Line -16777216 false 150 135 15 75
Line -16777216 false 150 135 285 75

bug
true
0
Circle -7500403 true true 96 182 108
Circle -7500403 true true 110 127 80
Circle -7500403 true true 110 75 80
Line -7500403 true 150 100 80 30
Line -7500403 true 150 100 220 30

butterfly
true
0
Polygon -7500403 true true 150 165 209 199 225 225 225 255 195 270 165 255 150 240
Polygon -7500403 true true 150 165 89 198 75 225 75 255 105 270 135 255 150 240
Polygon -7500403 true true 139 148 100 105 55 90 25 90 10 105 10 135 25 180 40 195 85 194 139 163
Polygon -7500403 true true 162 150 200 105 245 90 275 90 290 105 290 135 275 180 260 195 215 195 162 165
Polygon -16777216 true false 150 255 135 225 120 150 135 120 150 105 165 120 180 150 165 225
Circle -16777216 true false 135 90 30
Line -16777216 false 150 105 195 60
Line -16777216 false 150 105 105 60

car
false
0
Polygon -7500403 true true 300 180 279 164 261 144 240 135 226 132 213 106 203 84 185 63 159 50 135 50 75 60 0 150 0 165 0 225 300 225 300 180
Circle -16777216 true false 180 180 90
Circle -16777216 true false 30 180 90
Polygon -16777216 true false 162 80 132 78 134 135 209 135 194 105 189 96 180 89
Circle -7500403 true true 47 195 58
Circle -7500403 true true 195 195 58

circle
false
0
Circle -7500403 true true 0 0 300

circle 2
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240

cow
false
0
Polygon -7500403 true true 200 193 197 249 179 249 177 196 166 187 140 189 93 191 78 179 72 211 49 209 48 181 37 149 25 120 25 89 45 72 103 84 179 75 198 76 252 64 272 81 293 103 285 121 255 121 242 118 224 167
Polygon -7500403 true true 73 210 86 251 62 249 48 208
Polygon -7500403 true true 25 114 16 195 9 204 23 213 25 200 39 123

cylinder
false
0
Circle -7500403 true true 0 0 300

dot
false
0
Circle -7500403 true true 90 90 120

face happy
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 255 90 239 62 213 47 191 67 179 90 203 109 218 150 225 192 218 210 203 227 181 251 194 236 217 212 240

face neutral
false
0
Circle -7500403 true true 8 7 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Rectangle -16777216 true false 60 195 240 225

face sad
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 168 90 184 62 210 47 232 67 244 90 220 109 205 150 198 192 205 210 220 227 242 251 229 236 206 212 183

fish
false
0
Polygon -1 true false 44 131 21 87 15 86 0 120 15 150 0 180 13 214 20 212 45 166
Polygon -1 true false 135 195 119 235 95 218 76 210 46 204 60 165
Polygon -1 true false 75 45 83 77 71 103 86 114 166 78 135 60
Polygon -7500403 true true 30 136 151 77 226 81 280 119 292 146 292 160 287 170 270 195 195 210 151 212 30 166
Circle -16777216 true false 215 106 30

flag
false
0
Rectangle -7500403 true true 60 15 75 300
Polygon -7500403 true true 90 150 270 90 90 30
Line -7500403 true 75 135 90 135
Line -7500403 true 75 45 90 45

flower
false
0
Polygon -10899396 true false 135 120 165 165 180 210 180 240 150 300 165 300 195 240 195 195 165 135
Circle -7500403 true true 85 132 38
Circle -7500403 true true 130 147 38
Circle -7500403 true true 192 85 38
Circle -7500403 true true 85 40 38
Circle -7500403 true true 177 40 38
Circle -7500403 true true 177 132 38
Circle -7500403 true true 70 85 38
Circle -7500403 true true 130 25 38
Circle -7500403 true true 96 51 108
Circle -16777216 true false 113 68 74
Polygon -10899396 true false 189 233 219 188 249 173 279 188 234 218
Polygon -10899396 true false 180 255 150 210 105 210 75 240 135 240

house
false
0
Rectangle -7500403 true true 45 120 255 285
Rectangle -16777216 true false 120 210 180 285
Polygon -7500403 true true 15 120 150 15 285 120
Line -16777216 false 30 120 270 120

leaf
false
0
Polygon -7500403 true true 150 210 135 195 120 210 60 210 30 195 60 180 60 165 15 135 30 120 15 105 40 104 45 90 60 90 90 105 105 120 120 120 105 60 120 60 135 30 150 15 165 30 180 60 195 60 180 120 195 120 210 105 240 90 255 90 263 104 285 105 270 120 285 135 240 165 240 180 270 195 240 210 180 210 165 195
Polygon -7500403 true true 135 195 135 240 120 255 105 255 105 285 135 285 165 240 165 195

line
true
0
Line -7500403 true 150 0 150 300

line half
true
0
Line -7500403 true 150 0 150 150

pentagon
false
0
Polygon -7500403 true true 150 15 15 120 60 285 240 285 285 120

person
false
0
Circle -7500403 true true 110 5 80
Polygon -7500403 true true 105 90 120 195 90 285 105 300 135 300 150 225 165 300 195 300 210 285 180 195 195 90
Rectangle -7500403 true true 127 79 172 94
Polygon -7500403 true true 195 90 240 150 225 180 165 105
Polygon -7500403 true true 105 90 60 150 75 180 135 105

plant
false
0
Rectangle -7500403 true true 135 90 165 300
Polygon -7500403 true true 135 255 90 210 45 195 75 255 135 285
Polygon -7500403 true true 165 255 210 210 255 195 225 255 165 285
Polygon -7500403 true true 135 180 90 135 45 120 75 180 135 210
Polygon -7500403 true true 165 180 165 210 225 180 255 120 210 135
Polygon -7500403 true true 135 105 90 60 45 45 75 105 135 135
Polygon -7500403 true true 165 105 165 135 225 105 255 45 210 60
Polygon -7500403 true true 135 90 120 45 150 15 180 45 165 90

sheep
false
15
Circle -1 true true 203 65 88
Circle -1 true true 70 65 162
Circle -1 true true 150 105 120
Polygon -7500403 true false 218 120 240 165 255 165 278 120
Circle -7500403 true false 214 72 67
Rectangle -1 true true 164 223 179 298
Polygon -1 true true 45 285 30 285 30 240 15 195 45 210
Circle -1 true true 3 83 150
Rectangle -1 true true 65 221 80 296
Polygon -1 true true 195 285 210 285 210 240 240 210 195 210
Polygon -7500403 true false 276 85 285 105 302 99 294 83
Polygon -7500403 true false 219 85 210 105 193 99 201 83

square
false
0
Rectangle -7500403 true true 30 30 270 270

square 2
false
0
Rectangle -7500403 true true 30 30 270 270
Rectangle -16777216 true false 60 60 240 240

star
false
0
Polygon -7500403 true true 151 1 185 108 298 108 207 175 242 282 151 216 59 282 94 175 3 108 116 108

target
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240
Circle -7500403 true true 60 60 180
Circle -16777216 true false 90 90 120
Circle -7500403 true true 120 120 60

tree
false
0
Circle -7500403 true true 118 3 94
Rectangle -6459832 true false 120 195 180 300
Circle -7500403 true true 65 21 108
Circle -7500403 true true 116 41 127
Circle -7500403 true true 45 90 120
Circle -7500403 true true 104 74 152

triangle
false
0
Polygon -7500403 true true 150 30 15 255 285 255

triangle 2
false
0
Polygon -7500403 true true 150 30 15 255 285 255
Polygon -16777216 true false 151 99 225 223 75 224

truck
false
0
Rectangle -7500403 true true 4 45 195 187
Polygon -7500403 true true 296 193 296 150 259 134 244 104 208 104 207 194
Rectangle -1 true false 195 60 195 105
Polygon -16777216 true false 238 112 252 141 219 141 218 112
Circle -16777216 true false 234 174 42
Rectangle -7500403 true true 181 185 214 194
Circle -16777216 true false 144 174 42
Circle -16777216 true false 24 174 42
Circle -7500403 false true 24 174 42
Circle -7500403 false true 144 174 42
Circle -7500403 false true 234 174 42

turtle
true
0
Polygon -10899396 true false 215 204 240 233 246 254 228 266 215 252 193 210
Polygon -10899396 true false 195 90 225 75 245 75 260 89 269 108 261 124 240 105 225 105 210 105
Polygon -10899396 true false 105 90 75 75 55 75 40 89 31 108 39 124 60 105 75 105 90 105
Polygon -10899396 true false 132 85 134 64 107 51 108 17 150 2 192 18 192 52 169 65 172 87
Polygon -10899396 true false 85 204 60 233 54 254 72 266 85 252 107 210
Polygon -7500403 true true 119 75 179 75 209 101 224 135 220 225 175 261 128 261 81 224 74 135 88 99

wheel
false
0
Circle -7500403 true true 3 3 294
Circle -16777216 true false 30 30 240
Line -7500403 true 150 285 150 15
Line -7500403 true 15 150 285 150
Circle -7500403 true true 120 120 60
Line -7500403 true 216 40 79 269
Line -7500403 true 40 84 269 221
Line -7500403 true 40 216 269 79
Line -7500403 true 84 40 221 269

wolf
false
0
Polygon -16777216 true false 253 133 245 131 245 133
Polygon -7500403 true true 2 194 13 197 30 191 38 193 38 205 20 226 20 257 27 265 38 266 40 260 31 253 31 230 60 206 68 198 75 209 66 228 65 243 82 261 84 268 100 267 103 261 77 239 79 231 100 207 98 196 119 201 143 202 160 195 166 210 172 213 173 238 167 251 160 248 154 265 169 264 178 247 186 240 198 260 200 271 217 271 219 262 207 258 195 230 192 198 210 184 227 164 242 144 259 145 284 151 277 141 293 140 299 134 297 127 273 119 270 105
Polygon -7500403 true true -1 195 14 180 36 166 40 153 53 140 82 131 134 133 159 126 188 115 227 108 236 102 238 98 268 86 269 92 281 87 269 103 269 113

x
false
0
Polygon -7500403 true true 270 75 225 30 30 225 75 270
Polygon -7500403 true true 30 75 75 30 270 225 225 270
@#$#@#$#@
NetLogo 6.4.0
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
default
0.0
-0.2 0 0.0 1.0
0.0 1 1.0 0.0
0.2 0 0.0 1.0
link direction
true
0
Line -7500403 true 150 150 90 180
Line -7500403 true 150 150 210 180
@#$#@#$#@
0
@#$#@#$#@
