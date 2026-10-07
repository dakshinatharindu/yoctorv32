# =============================================================================
# fpga/zc702/scripts/build.tcl
# =============================================================================
# Vivado non-project flow for milestone 1: soc_top + block RAM on the ZC702,
# running the bare-metal program built by fpga/zc702/sw/hello/build.sh.
#
# Usage (from any directory, after running sw/hello/build.sh):
#   vivado -mode batch -source fpga/zc702/scripts/build.tcl
#
# The RTL list comes from sim/verilator/rtl.f, the same file every simulation
# script reads, so there is one list of sources for simulation and FPGA.
#
# Outputs land in fpga/zc702/build/:
#   yoctorv32.bit   bitstream to program over JTAG
#   timing.rpt      timing summary (check that WNS is not negative)
#   util.rpt        resource utilization
# =============================================================================

set here [file dirname [file normalize [info script]]]
set root [file normalize $here/../../..]
set fpga [file normalize $here/..]
set out  $fpga/build
file mkdir $out

set mem_file $out/hello.mem
if {![file exists $mem_file]} {
  error "missing $mem_file: run fpga/zc702/sw/hello/build.sh first"
}

# fpga_top.sv loads "hello.mem" by bare name, so synthesis runs from a
# directory that holds it. That directory is a scratch one with a copy of the
# file: Vivado removes the init file from its working directory once synthesis
# has read it, which would otherwise delete the build output itself.
set run $out/vivado_run
file mkdir $run
file copy -force $mem_file $run/hello.mem
set mem_copy $run/hello.mem
cd $run

# A $readmemh file that cannot be opened is only a critical warning by
# default, which would leave the RAM empty without failing the build.
set_msg_config -id {Synth 8-4445} -new_severity ERROR

# ---------------------------------------------------------------------------
# Sources. rtl.f lists core_pkg.sv first, which read order must preserve.
# ---------------------------------------------------------------------------
set fh [open $root/sim/verilator/rtl.f r]
set lines [split [read $fh] "\n"]
close $fh

set n_rtl 0
foreach line $lines {
  set line [string trim [lindex [split $line "#"] 0]]
  if {![string match "rtl/*" $line]} { continue }
  foreach f [lsort [glob $root/$line]] {
    read_verilog -sv $f
    incr n_rtl
  }
}
puts "Read $n_rtl RTL files from sim/verilator/rtl.f"

read_verilog -sv $fpga/rtl/fpga_top.sv
read_mem $mem_copy
read_xdc $fpga/constr/zc702.xdc

# ---------------------------------------------------------------------------
# Synthesis, then confirm the program actually made it into the block RAM.
# ---------------------------------------------------------------------------
synth_design -top fpga_top -part xc7z020clg484-1

set brams [get_cells -hierarchical -filter {REF_NAME =~ RAMB*}]
if {[llength $brams] == 0} {
  puts "NOTE: the program memory was not mapped to block RAM primitives; skipping the init check"
} else {
  set loaded 0
  foreach c $brams {
    if {![regexp {^[0-9]+'h0+$} [get_property INIT_00 $c]]} { set loaded 1 }
  }
  if {!$loaded} {
    error "block RAM contents are all zero: $mem_file was not loaded by \$readmemh"
  }
  puts "Program memory: [llength $brams] block RAM primitives, init data present"
}

# ---------------------------------------------------------------------------
# Implementation and bitstream.
# ---------------------------------------------------------------------------
opt_design
place_design
route_design

report_timing_summary -file $out/timing.rpt
report_utilization -file $out/util.rpt
write_bitstream -force $out/yoctorv32.bit

puts "Bitstream written to $out/yoctorv32.bit"
