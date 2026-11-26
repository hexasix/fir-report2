if {[catch {
    set run_dir [file normalize $::env(PT_RUN_DIR)]
    set target_db $::env(TARGET_DB)
    set netlist [file join $run_dir fir_alu.nl.v]
    set sdc [file join $run_dir fir_alu.sdc]
    set vcd [file join $run_dir fir_alu.vcd]
    foreach path [list $target_db $netlist $sdc $vcd] {
        if {![file isfile $path] || ![file readable $path] || [file size $path] == 0} {
            error "Missing, empty, or unreadable input: $path"
        }
    }
    cd $run_dir
    set_app_var power_enable_analysis true
    set_app_var power_analysis_mode averaged
    set_app_var search_path [concat [get_app_var search_path] [list $run_dir [file dirname $target_db]]]
    set_app_var link_path [list * $target_db]
    puts "PrimeTime netlist: $netlist"
    read_verilog $netlist
    if {![link_design fir_alu]} {error "Link failed"}
    read_sdc $sdc
    update_timing
    redirect [file join $run_dir pt_check.rpt] {check_timing -verbose}
    redirect [file join $run_dir pt_setup.rpt] {report_timing -delay_type max -max_paths 10}
    redirect [file join $run_dir pt_hold.rpt] {report_timing -delay_type min -max_paths 10}
    redirect [file join $run_dir pt_summary.rpt] {report_global_timing}
    read_vcd -strip_path tb_fir_alu/dut $vcd
    update_power
    redirect [file join $run_dir pt_activity.rpt] {report_switching_activity -list_not_annotated}
    redirect [file join $run_dir pt_power.rpt] {report_power}
} reason]} {
    puts stderr "PrimeTime flow failed: $reason"
    exit 1
}
exit 0
