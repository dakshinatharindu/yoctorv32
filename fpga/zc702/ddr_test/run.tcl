# =============================================================================
# fpga/zc702/ddr_test/run.tcl
# =============================================================================
# Runs the milestone 2, step 2 DDR test on the ZC702 over JTAG (xsdb):
#   1. resets the Zynq PS (this also clears the PL)
#   2. programs the PL with build/ddr_test.bit
#   3. initializes the PS with build/ps7_init.tcl: clocks, DDR controller
#   4. writes a fresh value into the test's mailbox word in DDR
#   5. releases the PL (ps7_post_config), which starts the test
#   6. waits for the first pass and checks, by reading DDR back through the
#      debugger, that the PL saw the mailbox value and reported a clean pass
#
# The test itself keeps running afterwards and prints one line per pass on
# the serial port (9600 baud); see ddr_test_core.sv for the line format.
#
# Usage, with the board in JTAG boot mode and build.tcl already run:
#   xsdb fpga/zc702/ddr_test/run.tcl
# =============================================================================

set here [file dirname [file normalize [info script]]]
set bit  $here/build/ddr_test.bit
set init $here/build/ps7_init.tcl

# Must match MBOX_BASE in ddr_test_core.sv.
set MBOX 0x14000000

foreach f [list $bit $init] {
  if {![file exists $f]} {
    puts "ERROR: $f not found. Run: vivado -mode batch -source fpga/zc702/ddr_test/build.tcl"
    exit 1
  }
}

# Read one 32-bit word. mrd prints "ADDRESS:   VALUE".
proc rd32 {addr} {
  return [expr {"0x[string trim [lindex [split [mrd -force $addr] ":"] 1]]"}]
}

proc select_apu {} {
  targets -set -nocase -filter {name =~ "APU*"}
}

connect
puts "\n== Targets =="
puts [targets]

puts "\n== 1. Resetting the PS =="
select_apu
rst -system
after 3000

puts "\n== 2. Programming the PL: $bit =="
targets -set -nocase -filter {name =~ "xc7z020*"}
fpga -file $bit

puts "\n== 3. Initializing the PS (clocks, DDR) =="
select_apu
configparams force-mem-accesses 1
source $init
ps7_init

puts "\n== 4. Preparing the mailbox at [format 0x%08X $MBOX] =="
set mbox_value [expr {([clock seconds] * 2654435761) & 0xFFFFFFFF}]
mwr -force $MBOX $mbox_value
mwr -force [expr {$MBOX + 0x4}] 0
mwr -force [expr {$MBOX + 0x8}] 0xFFFFFFFF
mwr -force [expr {$MBOX + 0xC}] 0
set check [rd32 $MBOX]
if {$check != $mbox_value} {
  puts [format "ERROR: DDR does not hold what the debugger wrote (wrote %08X, read %08X)." $mbox_value $check]
  puts "       The PS DDR controller is not working; the PL test cannot pass."
  exit 1
}
puts [format "mailbox = %08X (read back correctly through the debugger)" $mbox_value]

puts "\n== 5. Releasing the PL: the test starts now =="
ps7_post_config

puts "\n== 6. Waiting for the first pass (64 MiB written and read back) =="
set status 0
set waited 0
while {$waited < 300} {
  after 2000
  incr waited 2
  set status [rd32 [expr {$MBOX + 0xC}]]
  if {$status != 0} { break }
  if {$waited % 10 == 0} { puts "  ... ${waited}s" }
}

set echo   [rd32 [expr {$MBOX + 0x4}]]
set passno [rd32 [expr {$MBOX + 0x8}]]
set want   [expr {~$mbox_value & 0xFFFFFFFF}]

puts ""
puts [format "status word      = %08X  (600Dnnnn = pass nnnn was clean, BAD0nnnn = it failed)" $status]
puts [format "mailbox echo     = %08X  (expected %08X)" $echo $want]
puts [format "pass now running = %08X" $passno]

set ok 1
if {$status == 0} {
  puts "FAIL: no pass finished within ${waited}s. Is LED DS16 on? Is anything printed on the serial port?"
  set ok 0
} elseif {($status >> 16) != 0x600D} {
  puts "FAIL: the PL reported a failed pass. The serial line shows the first bad address and value."
  set ok 0
}
if {$echo != $want} {
  puts "FAIL: the PL did not read the mailbox value the debugger wrote."
  set ok 0
}

if {$ok} {
  puts "\nPASS: the PL reads and writes PS DDR correctly, in both directions with the debugger."
  puts "The test keeps running; the latency figures are in the serial output (rd=min-max wr=min-max)."
} else {
  puts "\nDDR test FAILED."
}
exit [expr {$ok ? 0 : 1}]
