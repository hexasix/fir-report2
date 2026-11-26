set root $::env(REPORT2_DIR)
set pwd_out [pwd]
set_app_var search_path [concat [get_app_var search_path] [list [file dirname $::env(TARGET_DB)]]]
set_app_var target_library [list $::env(TARGET_DB)]
set_app_var synthetic_library [list dw_foundation.sldb]
set_app_var link_library [concat [list *] $target_library $synthetic_library]
file mkdir dc_work
if {[catch {
    define_design_lib WORK -path [file join $pwd_out dc_work]
    set rtl [file join $root rtl fir_alu.v]
    if {$::env(COMPILE_PROFILE) eq "pipeline"} {
        analyze -format verilog -define {FIR_ALU_PIPELINED} $rtl
    } else {
        analyze -format verilog $rtl
    }
    elaborate fir_alu
    current_design fir_alu
    if {![link]} {error "Link failed"}
    check_design
    source [file join $root flow constraints.tcl]
    if {$::env(COMPILE_PROFILE) eq "area"} {
        compile_ultra -no_autoungroup -area_high_effort_script
    } else {
        compile_ultra -no_autoungroup
    }
    change_names -rules verilog -hierarchy
    write -format verilog -hierarchy -output fir_alu.nl.v
    write_sdc fir_alu.sdc
    write_sdf -version 2.1 fir_alu.sdf
    redirect dc_area.rpt {report_area -hierarchy}
    redirect dc_timing.rpt {report_timing -delay_type max -max_paths 10}
    redirect dc_constraints.rpt {report_constraint -all_violators}
    redirect dc_references.rpt {report_reference -hierarchy}
} reason]} {
    puts stderr "DC flow failed: $reason"
    exit 1
}
exit 0
