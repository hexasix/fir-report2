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
RUN_DIR="${RUN_DIR:-$REPORT2_DIR/build/course_${CLOCK_NS}ns_${COMPILE_PROFILE}}"

fail() { printf '%s\n' "$*" >&2; exit 1; }
for tool in "$DC" "$PT" "$VLIB" "$VLOG" "$VSIM"; do
    command -v "$tool" >/dev/null || fail "Tool not found: $tool. Run on the course EDA host with the Lab 3/4 environment loaded."
done
[[ "$CLOCK_NS" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail 'CLOCK_NS must be a positive decimal number.'
awk -v p="$CLOCK_NS" 'BEGIN { exit !(p > 0) }' || fail 'CLOCK_NS must be greater than zero.'
[[ "$COMPILE_PROFILE" == baseline || "$COMPILE_PROFILE" == area ]] || fail 'COMPILE_PROFILE must be baseline or area.'
[[ "$POWER_SAMPLES" =~ ^[1-9][0-9]*$ ]] || fail 'POWER_SAMPLES must be a positive integer.'
[[ "$SEED" =~ ^[0-9a-fA-F]{1,8}$ && ! "$SEED" =~ ^0+$ ]] || fail 'SEED must be nonzero hexadecimal without 0x.'
[[ "$SDF_SIM" == 0 || "$SDF_SIM" == 1 ]] || fail 'SDF_SIM must be 0 or 1.'
[[ -r "$TARGET_DB" ]] || fail "Cannot read target library: $TARGET_DB"
IFS=: read -r -a model_files <<< "$CELL_MODELS"
for path in "$TARGET_DB" "${model_files[@]}"; do
    [[ "$path" == /* && -f "$path" && -r "$path" ]] || fail "Expected a readable absolute library path: $path"
done
[[ ! -e "$RUN_DIR" ]] || fail "Run directory already exists; choose a fresh RUN_DIR: $RUN_DIR"
mkdir -p "$(dirname "$RUN_DIR")"
mkdir "$RUN_DIR"
cd "$RUN_DIR"
printf 'clock_ns=%s\nprofile=%s\nlib=%s\nseed=%s\npower_samples=%s\nsdf_sim=%s\n' \
    "$CLOCK_NS" "$COMPILE_PROFILE" "$TARGET_DB" "$SEED" "$POWER_SAMPLES" "$SDF_SIM" > run_config.txt

require_outputs() {
    for path in "$@"; do [[ -s "$path" ]] || fail "Missing or empty output: $path"; done
}

"$DC" -f "$REPORT2_DIR/flow/dc.tcl" 2>&1 | tee dc.log
require_outputs fir_alu.nl.v fir_alu.sdc fir_alu.sdf dc_area.rpt dc_timing.rpt dc_constraints.rpt dc_references.rpt

"$VLIB" work
"$VLOG" -sv "${model_files[@]}" fir_alu.nl.v "$REPORT2_DIR/tb/tb_fir_alu.v" 2>&1 | tee vlog.log
run_sim() {
    local logfile="$1"
    shift
    "$VSIM" -c -onfinish stop -voptargs=+acc -t 1ps "-gCLK_PERIOD_NS=$CLOCK_NS" \
        -do 'onerror {quit -code 1}; run -all; quit -code 0' "$@" 2>&1 | tee "$logfile"
    grep -q 'PASS:' "$logfile" || fail "No testbench PASS marker: $logfile"
}
run_sim gate.log work.tb_fir_alu "+SEED=$SEED"
run_sim activity.log work.tb_fir_alu "+SEED=$SEED" +power "+POWER_SAMPLES=$POWER_SAMPLES"
require_outputs fir_alu.vcd

"$PT" -f "$REPORT2_DIR/flow/pt.tcl" 2>&1 | tee pt.log
require_outputs pt_setup.rpt pt_hold.rpt pt_summary.rpt pt_check.rpt pt_activity.rpt pt_power.rpt

# Failures here do not remove the functional or static results. Cell delays
# may expose a real violation at the target period. Do not suppress warnings.
if [[ "$SDF_SIM" == 1 ]]; then
    sim_delay=$(awk -v period="$CLOCK_NS" 'BEGIN { printf "%.4f", period * 0.4 }')
    run_sim gate_sdf.log -sdfmax /tb_fir_alu/dut=fir_alu.sdf work.tb_fir_alu "+SEED=$SEED" "+CHECK_DELAY_NS=$sim_delay"
fi
printf '\nCourse run outputs: %s\nReview slack, activity annotation coverage, and power units before citing results.\n' "$PWD"
