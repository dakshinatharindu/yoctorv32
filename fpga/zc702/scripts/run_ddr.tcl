# =============================================================================
# fpga/zc702/scripts/run_ddr.tcl
# =============================================================================
# Starts the milestone 2 design (fpga_top_ddr: the SoC running out of PS DDR)
# on the ZC702 over JTAG (xsdb):
#   1. resets the Zynq PS (this also clears the PL)
#   2. programs the PL with build/yoctorv32_ddr.bit
#   3. initializes the PS with build/ps7_init.tcl: clocks, DDR controller
#   4. copies the given images into DDR and spot-checks them
#   5. releases the PL (ps7_post_config): the core leaves reset, the boot
#      program in the boot RAM prints its banner on the serial port (9600
#      baud) and jumps to 0x80000000 if it finds an image there
#
# Usage, with the board in JTAG boot mode and build_ddr.tcl already run:
#   xsdb fpga/zc702/scripts/run_ddr.tcl [<file> <address> ...]
#
# Each <file> is a raw binary and <address> is where the core should see it,
# inside main RAM (0x80000000..0x83FFFFFF). For example:
#   xsdb fpga/zc702/scripts/run_ddr.tcl fpga/zc702/build/hello_ddr.bin 0x80000000
# With no images, the word the boot program checks is cleared instead, so it
# reports "no image" rather than starting whatever a previous run left in DDR.
#
# Every start goes through this script: SW5 restarts the core, but a program
# that has modified its own image (a booted kernel, say) needs reloading.
# =============================================================================

set here [file dirname [file normalize [info script]]]
set out  [file normalize $here/../build]
set bit  $out/yoctorv32_ddr.bit
set init $out/ps7_init.tcl

# Must match RAM_BASE / RAM_BYTES / DDR_BASE in fpga/zc702/rtl/mem_bridge.sv
# and IMAGE_MAGIC_OFFSET in fpga/zc702/sw/common/soc.h.
set RAM_BASE   0x80000000
set RAM_BYTES  0x04000000
set DDR_BASE   0x10000000
set MAGIC_OFF  0x38

if {[llength $argv] % 2 != 0} {
  puts "usage: xsdb run_ddr.tcl \[<file> <address> ...\]"
  exit 1
}
foreach f [list $bit $init] {
  if {![file exists $f]} {
    puts "ERROR: $f not found. Run fpga/zc702/sw/boot/build.sh, then:"
    puts "       vivado -mode batch -source fpga/zc702/scripts/build_ddr.tcl"
    exit 1
  }
}

# Validate the images before touching the board.
set images {}
foreach {file addr} $argv {
  set file [file normalize $file]
  if {![file exists $file]} {
    puts "ERROR: image not found: $file"
    exit 1
  }
  set size [file size $file]
  if {$addr < $RAM_BASE || ($addr + $size) > ($RAM_BASE + $RAM_BYTES)} {
    puts [format "ERROR: %s (%d bytes) at 0x%08X does not fit in main RAM 0x%08X..0x%08X" \
              $file $size $addr $RAM_BASE [expr {$RAM_BASE + $RAM_BYTES - 1}]]
    exit 1
  }
  lappend images [list $file $addr $size]
}

# Read one 32-bit word. mrd prints "ADDRESS:   VALUE".
proc rd32 {addr} {
  return [expr {"0x[string trim [lindex [split [mrd -force $addr] ":"] 1]]"}]
}

# The little-endian 32-bit word at a byte offset of a file.
proc file_word {file offset} {
  set fh [open $file rb]
  seek $fh $offset
  binary scan [read $fh 4] iu word
  close $fh
  return $word
}

proc select_apu {} {
  targets -set -nocase -filter {name =~ "APU*"}
}

connect

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

puts "\n== 4. Loading DDR =="
if {[llength $images] == 0} {
  mwr -force [expr {$DDR_BASE + $MAGIC_OFF}] 0
  puts "no images given: cleared the image marker, the boot program will report \"no image\""
}
foreach image $images {
  lassign $image file addr size
  set ddr [expr {$addr - $RAM_BASE + $DDR_BASE}]
  puts [format "%s: %d bytes -> core address 0x%08X (DDR 0x%08X)" [file tail $file] $size $addr $ddr]
  dow -data $file $ddr

  # Spot-check the first and last whole words through the debugger.
  foreach offset [list 0 [expr {($size - 4) & ~3}]] {
    if {$offset < 0 || $offset + 4 > $size} { continue }
    set want [file_word $file $offset]
    set got  [rd32 [expr {$ddr + $offset}]]
    if {$got != $want} {
      puts [format "ERROR: read-back mismatch at +0x%X: wrote %08X, DDR holds %08X" $offset $want $got]
      exit 1
    }
  }
  puts "  read-back check passed"
}

puts "\n== 5. Releasing the PL: the core starts now =="
ps7_post_config

puts "\nRunning. LED DS16 should be on and the boot banner should appear on the serial port."
puts "SW5 restarts the core without reloading DDR."
exit 0
