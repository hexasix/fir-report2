set_app_var power_enable_analysis true
set_app_var power_analysis_mode averaged
set_app_var search_path [concat [get_app_var search_path] [list [file dirname $::env(TARGET_DB)]]]
set_app_var link_path [list * $::env(TARGET_DB)]
if {[catch {
    read_verilog fir_alu.nl.v
    current_design fir_alu
    if {![link_design fir_alu]} {error "Link failed"}
    read_sdc fir_alu.sdc
    update_timing
    redirect pt_check.rpt {check_timing -verbose}
    redirect pt_setup.rpt {report_timing -delay_type max -max_paths 10}
    redirect pt_hold.rpt {report_timing -delay_type min -max_paths 10}
    redirect pt_summary.rpt {report_global_timing}
    read_vcd -strip_path tb_fir_alu/dut fir_alu.vcd
    update_power
    redirect pt_activity.rpt {report_switching_activity -list_not_annotated}
    redirect pt_power.rpt {report_power}
} reason]} {
    puts stderr "PrimeTime flow failed: $reason"
    exit 1
}
exit 0
