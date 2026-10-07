# =============================================================================
# fpga/zc702/ddr_test/build.tcl
# =============================================================================
# Builds the milestone 2, step 2 DDR test for the ZC702: a Vivado project
# (needed for the Zynq PS block design) created fresh under build/, then
# synthesis, implementation and bitstream.
#
# Usage (from any directory):
#   vivado -mode batch -source fpga/zc702/ddr_test/build.tcl
#
# Outputs land in fpga/zc702/ddr_test/build/:
#   ddr_test.bit    bitstream
#   ps7_init.tcl    PS initialization script for xsdb (used by run.tcl)
#   timing.rpt      timing summary (check that WNS is not negative)
#   util.rpt        resource utilization
#   proj/           the generated Vivado project, safe to delete
# =============================================================================

set here [file dirname [file normalize [info script]]]
set fpga [file normalize $here/..]
set out  $here/build
file mkdir $out

create_project -force ddr_test $out/proj -part xc7z020clg484-1

source $fpga/bd/ps7.tcl
set ps7_init [create_ps7_bd 50000000]
file copy -force $ps7_init $out/ps7_init.tcl

add_files -norecurse [list \
    $fpga/rtl/hp_axi_master.sv \
    $here/ddr_test_core.sv \
    $here/ddr_test_top.sv \
]
add_files -fileset constrs_1 -norecurse $here/ddr_test.xdc
set_property top ddr_test_top [current_fileset]
update_compile_order -fileset sources_1

synth_design -top ddr_test_top -part xc7z020clg484-1
opt_design
place_design
route_design

report_timing_summary -file $out/timing.rpt
report_utilization -file $out/util.rpt
write_bitstream -force $out/ddr_test.bit

puts "Bitstream written to $out/ddr_test.bit"
puts "PS init script copied to $out/ps7_init.tcl"
