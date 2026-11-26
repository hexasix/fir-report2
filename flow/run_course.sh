#!/usr/bin/env bash
# Execute from anywhere; the results are confined to a new run directory.
set -euo pipefail
export REPORT2_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export CLOCK_NS="${CLOCK_NS:-2.0}"
export TARGET_DB="${TARGET_DB:-/courses/ee6321/share/ibm13rflpvt/synopsys/scx3_cmos8rf_lpvt_tt_1p2v_25c.db}"
CELL_MODELS="${CELL_MODELS:-/courses/ee6321/share/ibm13rflpvt/verilog/ibm13rflpvt.v}"
export COMPILE_PROFILE="${COMPILE_PROFILE:-baseline}"
POWER_SAMPLES="${POWER_SAMPLES:-10000}"
SEED="${SEED:-48230002}"
DC="${DC:-dc_shell}"
PT="${PT:-pt_shell}"
VLIB="${VLIB:-vlib}"
VLOG="${VLOG:-vlog}"
VSIM="${VSIM:-vsim}"
SDF_SIM="${SDF_SIM:-0}"
TIMING_ONLY="${TIMING_ONLY:-0}"
last_group_latency=6
[[ "$COMPILE_PROFILE" != pipeline ]] || last_group_latency=9
REUSE_DC_FROM="${REUSE_DC_FROM:-}"
run_suffix=""
[[ -z "$REUSE_DC_FROM" ]] || run_suffix="_gate_retry"
RUN_DIR="${RUN_DIR:-$REPORT2_DIR/build/course_${CLOCK_NS}ns_${COMPILE_PROFILE}${run_suffix}}"
DC_ARTIFACTS=(fir_alu.nl.v fir_alu.sdc fir_alu.sdf dc_area.rpt dc_timing.rpt dc_constraints.rpt dc_references.rpt dc.log)

fail() { printf '%s\n' "$*" >&2; exit 1; }
required_tools=("$PT")
[[ "$TIMING_ONLY" == 1 ]] || required_tools+=("$VLIB" "$VLOG" "$VSIM")
[[ -n "$REUSE_DC_FROM" ]] || required_tools+=("$DC")
for tool in "${required_tools[@]}"; do
    command -v "$tool" >/dev/null || fail "Tool not found: $tool. Run on the course EDA host with the Lab 3/4 environment loaded."
done
[[ "$CLOCK_NS" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail 'CLOCK_NS must be a positive decimal number.'
awk -v p="$CLOCK_NS" 'BEGIN { exit !(p > 0) }' || fail 'CLOCK_NS must be greater than zero.'
[[ "$COMPILE_PROFILE" == baseline || "$COMPILE_PROFILE" == area || "$COMPILE_PROFILE" == pipeline ]] || fail 'COMPILE_PROFILE must be baseline, area, or pipeline.'
[[ "$POWER_SAMPLES" =~ ^[1-9][0-9]*$ ]] || fail 'POWER_SAMPLES must be a positive integer.'
[[ "$SEED" =~ ^[0-9a-fA-F]{1,8}$ && ! "$SEED" =~ ^0+$ ]] || fail 'SEED must be nonzero hexadecimal without 0x.'
[[ "$SDF_SIM" == 0 || "$SDF_SIM" == 1 ]] || fail 'SDF_SIM must be 0 or 1.'
[[ "$TARGET_DB" == /* && -f "$TARGET_DB" && -r "$TARGET_DB" ]] || fail "Expected a readable absolute target library path: $TARGET_DB"
[[ "$TIMING_ONLY" == 0 || "$TIMING_ONLY" == 1 ]] || fail 'TIMING_ONLY must be 0 or 1.'
if [[ "$TIMING_ONLY" == 1 ]]; then
    [[ "$SDF_SIM" == 0 ]] || fail 'SDF_SIM requires TIMING_ONLY=0.'
else
    IFS=: read -r -a model_files <<< "$CELL_MODELS"
    for path in "${model_files[@]}"; do
        [[ "$path" == /* && -f "$path" && -r "$path" ]] || fail "Expected a readable absolute model path: $path"
    done
fi
require_outputs() {
    for path in "$@"; do [[ -s "$path" ]] || fail "Missing or empty output: $path"; done
}

if [[ -n "$REUSE_DC_FROM" ]]; then
    [[ -d "$REUSE_DC_FROM" ]] || fail "Cannot find synthesis directory: $REUSE_DC_FROM"
    REUSE_DC_FROM="$(cd "$REUSE_DC_FROM" && pwd)"
    require_outputs "$REUSE_DC_FROM/run_config.txt"
    for setting in "clock_ns=$CLOCK_NS" "profile=$COMPILE_PROFILE" "lib=$TARGET_DB"; do
        grep -Fxq -- "$setting" "$REUSE_DC_FROM/run_config.txt" ||
            fail "Previous synthesis configuration does not match: $setting"
    done
    for path in "${DC_ARTIFACTS[@]}"; do require_outputs "$REUSE_DC_FROM/$path"; done
fi

[[ ! -e "$RUN_DIR" ]] || fail "Run directory already exists; choose a fresh RUN_DIR: $RUN_DIR"
mkdir -p "$(dirname "$RUN_DIR")"
mkdir "$RUN_DIR"
cd "$RUN_DIR"
RUN_DIR="$PWD"
printf 'clock_ns=%s\nprofile=%s\nlib=%s\nseed=%s\npower_samples=%s\nsdf_sim=%s\nreuse_dc_from=%s\ntiming_only=%s\n' \
    "$CLOCK_NS" "$COMPILE_PROFILE" "$TARGET_DB" "$SEED" "$POWER_SAMPLES" "$SDF_SIM" "$REUSE_DC_FROM" "$TIMING_ONLY" > run_config.txt

if [[ -n "$REUSE_DC_FROM" ]]; then
    printf 'Reusing synthesis outputs from %s\n' "$REUSE_DC_FROM"
    for path in "${DC_ARTIFACTS[@]}"; do cp "$REUSE_DC_FROM/$path" "$path"; done
else
    "$DC" -f "$REPORT2_DIR/flow/dc.tcl" 2>&1 | tee dc.log
fi
require_outputs "${DC_ARTIFACTS[@]}"

if [[ "$TIMING_ONLY" == 1 ]]; then
    PT_RUN_DIR="$RUN_DIR" PT_TIMING_ONLY=1 "$PT" -f "$REPORT2_DIR/flow/pt.tcl" 2>&1 | tee pt.log
    require_outputs pt_setup.rpt pt_hold.rpt pt_summary.rpt pt_check.rpt
    printf '\nTiming-only results: %s\n' "$RUN_DIR"
    exit 0
fi

compile_sim() {
    local logfile="$1"
    shift
    "$VLIB" work
    {
        "$VLOG" -sv "$@" "${model_files[@]}" "$RUN_DIR/fir_alu.nl.v" &&
        "$VLOG" -sv "$REPORT2_DIR/tb/tb_fir_alu.v"
    } 2>&1 | tee "$logfile"
}
run_sim() {
    local logfile="$1"
    shift
    "$VSIM" -c -onfinish stop -voptargs=+acc -t 1ps "-gCLK_PERIOD_NS=$CLOCK_NS" \
        "-gLAST_GROUP_LATENCY=$last_group_latency" -do 'do $env(REPORT2_DIR)/flow/run_sim.do' "$@" 2>&1 | tee "$logfile"
    grep -q 'PASS:' "$logfile" || fail "No testbench PASS marker: $logfile"
}
# Apply the compiler's zero-delay mode to the standard-cell models too.
compile_sim vlog.log +delay_mode_zero
run_sim gate.log work.tb_fir_alu "+SEED=$SEED"
run_sim activity.log work.tb_fir_alu "+SEED=$SEED" +power "+POWER_SAMPLES=$POWER_SAMPLES"
require_outputs fir_alu.vcd

PT_RUN_DIR="$RUN_DIR" PT_TIMING_ONLY=0 "$PT" -f "$REPORT2_DIR/flow/pt.tcl" 2>&1 | tee pt.log
require_outputs pt_setup.rpt pt_hold.rpt pt_summary.rpt pt_check.rpt pt_activity.rpt pt_power.rpt

# Failures here do not remove the functional or static results. Cell delays
# may expose a real violation at the target period. Do not suppress warnings.
if [[ "$SDF_SIM" == 1 ]]; then
    sim_delay=$(awk -v period="$CLOCK_NS" 'BEGIN { printf "%.4f", period * 0.4 }')
    mkdir sdf_sim
    (
        cd sdf_sim
        compile_sim ../vlog_sdf.log
        run_sim ../gate_sdf.log -sdfmax "/tb_fir_alu/dut=$RUN_DIR/fir_alu.sdf" \
            work.tb_fir_alu "+SEED=$SEED" "+CHECK_DELAY_NS=$sim_delay"
    )
fi
printf '\nCourse run outputs: %s\nReview slack, activity annotation coverage, and power units before citing results.\n' "$PWD"
