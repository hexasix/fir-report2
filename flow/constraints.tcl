# Nanoseconds in the course library. Explicit standalone interface budget.
# No clock-tree or extracted interconnect is available at this stage.
set period $::env(CLOCK_NS)
create_clock -name core_clk -period $period [get_ports clk]
set data_inputs [remove_from_collection [all_inputs] [get_ports {clk rstn}]]
foreach direction {input output} {
    if {$direction eq "input"} { set ports $data_inputs } else { set ports [all_outputs] }
    set_${direction}_delay -clock core_clk -max [expr {0.1 * $period}] $ports
    set_${direction}_delay -clock core_clk -min 0.0 $ports
}
# Assumes an asynchronously asserted, locally synchronized reset release.
set_false_path -from [get_ports rstn]
