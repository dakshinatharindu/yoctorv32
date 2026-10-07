# =============================================================================
# fpga/zc702/scripts/build.tcl
# =============================================================================
# Builds the bitstream for the ZC702: soc_top running out of PS DDR
# (fpga_top.sv), with the boot program built by fpga/zc702/sw/build.sh baked
# into the boot RAM.
#
# It creates a Vivado project, fresh each time under build/proj/, because the
# Zynq PS block design (scripts/ps7.tcl) needs one.
#
# Usage (from any directory, after running sw/build.sh):
#   vivado -mode batch -source fpga/zc702/scripts/build.tcl
#
# The RTL list comes from sim/verilator/rtl.f, the same file every simulation
# script reads.
#
# Outputs land in fpga/zc702/build/:
#   yoctorv32.bit   bitstream
#   ps7_init.tcl    PS initialization script for xsdb (used by run.tcl)
#   timing.rpt      timing summary (check that WNS is not negative)
#   util.rpt        resource utilization
# =============================================================================

set here [file dirname [file normalize [info script]]]
set root [file normalize $here/../../..]
set fpga [file normalize $here/..]
set out  $fpga/build
file mkdir $out

set mem_file $out/boot.mem
if {![file exists $mem_file]} {
  error "missing $mem_file: run fpga/zc702/sw/build.sh first"
}

# fpga_top.sv loads "boot.mem" by bare name, so synthesis runs from a
# directory that holds it. That directory is a scratch one with a copy of the
# file: Vivado removes the init file from its working directory once synthesis
# has read it, which would otherwise delete the build output itself.
set run $out/vivado_run
file mkdir $run
file copy -force $mem_file $run/boot.mem
set mem_copy $run/boot.mem
cd $run

# A $readmemh file that cannot be opened is only a critical warning by
# default, which would leave the boot RAM empty without failing the build.
set_msg_config -id {Synth 8-4445} -new_severity ERROR

create_project -force yoctorv32 $out/proj -part xc7z020clg484-1

source $here/ps7.tcl
set ps7_init [create_ps7_bd 50000000]
file copy -force $ps7_init $out/ps7_init.tcl

# ---------------------------------------------------------------------------
# Sources. rtl.f lists core_pkg.sv first; update_compile_order keeps packages
# ahead of their users in any case.
# ---------------------------------------------------------------------------
set fh [open $root/sim/verilator/rtl.f r]
set lines [split [read $fh] "\n"]
close $fh

set rtl_files {}
foreach line $lines {
  set line [string trim [lindex [split $line "#"] 0]]
  if {![string match "rtl/*" $line]} { continue }
  foreach f [lsort [glob $root/$line]] { lappend rtl_files $f }
}
puts "Read [llength $rtl_files] RTL files from sim/verilator/rtl.f"

add_files -norecurse $rtl_files
add_files -norecurse [list \
    $fpga/rtl/hp_axi_master.sv \
    $fpga/rtl/mem_bridge.sv \
    $fpga/rtl/fpga_soc.sv \
    $fpga/rtl/fpga_top.sv \
    $mem_copy \
]
add_files -fileset constrs_1 -norecurse $fpga/zc702.xdc
set_property top fpga_top [current_fileset]
update_compile_order -fileset sources_1

# ---------------------------------------------------------------------------
# Synthesis, then confirm the boot program actually made it into the boot RAM.
# ---------------------------------------------------------------------------
synth_design -top fpga_top -part xc7z020clg484-1

set brams [get_cells -hierarchical -filter {REF_NAME =~ RAMB* && NAME =~ *boot_mem*}]
if {[llength $brams] == 0} {
  puts "NOTE: the boot RAM was not mapped to block RAM primitives; skipping the init check"
} else {
  set loaded 0
  foreach c $brams {
    if {![regexp {^[0-9]+'h0+$} [get_property INIT_00 $c]]} { set loaded 1 }
  }
  if {!$loaded} {
    error "boot RAM contents are all zero: $mem_file was not loaded by \$readmemh"
  }
  puts "Boot RAM: [llength $brams] block RAM primitive(s), init data present"
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
puts "PS init script copied to $out/ps7_init.tcl"
