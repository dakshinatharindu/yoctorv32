# =============================================================================
# fpga/zc702/uart_test/build.tcl
# =============================================================================
# Vivado non-project flow for the milestone 0 UART link check: synthesis,
# implementation and bitstream for uart_test_top on the ZC702.
#
# Usage (from any directory):
#   vivado -mode batch -source fpga/zc702/uart_test/build.tcl
#
# Outputs land in fpga/zc702/uart_test/build/:
#   uart_test.bit   bitstream to program over JTAG
#   timing.rpt      timing summary (check that WNS is not negative)
#   util.rpt        resource utilization
# =============================================================================

set here [file dirname [file normalize [info script]]]
set out  $here/build
file mkdir $out

read_verilog -sv $here/uart_test_top.sv
read_xdc $here/uart_test.xdc

synth_design -top uart_test_top -part xc7z020clg484-1
opt_design
place_design
route_design

report_timing_summary -file $out/timing.rpt
report_utilization -file $out/util.rpt
write_bitstream -force $out/uart_test.bit

puts "Bitstream written to $out/uart_test.bit"
