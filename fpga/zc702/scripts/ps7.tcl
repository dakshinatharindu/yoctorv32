# =============================================================================
# fpga/zc702/scripts/ps7.tcl
# =============================================================================
# Defines create_ps7_bd, which adds a block design holding only the Zynq
# processing system (PS) to the current Vivado project. The PL design uses
# the PS for exactly three things:
#   - its DDR controller, reached from the PL through the S_AXI_HP0 port
#     (AXI3, 32-bit data), clocked by a PL clock on hp0_aclk
#   - fclk_reset0_n, which stays low until the PS has been initialized
#     (ps7_init + ps7_post_config over JTAG) and can be pulsed from xsdb
#   - the DDR/MIO pins themselves, which must reach the top level
#
# The ZC702 board preset supplies the DDR part, the PS clock and the MIO
# setup. Generating the block design also produces ps7_init.tcl, the script
# that initializes the PS over JTAG; create_ps7_bd returns its path.
#
# Usage, inside a project created for xc7z020clg484-1:
#   source fpga/zc702/scripts/ps7.tcl
#   set ps7_init [create_ps7_bd 50000000]
# The top level then instantiates the generated module ps7_bd_wrapper.
# =============================================================================

proc create_ps7_bd {hp0_clk_hz} {
  set board [lindex [lsort [get_board_parts -quiet *zc702:part0*]] end]
  if {$board eq ""} { error "ZC702 board files not found in this Vivado install" }
  set_property board_part $board [current_project]

  create_bd_design ps7_bd
  set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7]
  apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
      -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps

  # No PS-to-PL master port and no PS-generated clock: the PL keeps its own
  # 200 MHz oscillator. Only the HP0 slave port and the reset output are used.
  set_property -dict [list \
      CONFIG.PCW_USE_M_AXI_GP0 {0} \
      CONFIG.PCW_USE_S_AXI_HP0 {1} \
      CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {32} \
      CONFIG.PCW_EN_CLK0_PORT {0} \
      CONFIG.PCW_EN_RST0_PORT {1} \
  ] $ps

  create_bd_port -dir I -type clk -freq_hz $hp0_clk_hz hp0_aclk
  connect_bd_net [get_bd_ports hp0_aclk] [get_bd_pins ps7/S_AXI_HP0_ACLK]

  create_bd_port -dir O -type rst fclk_reset0_n
  connect_bd_net [get_bd_ports fclk_reset0_n] [get_bd_pins ps7/FCLK_RESET0_N]

  make_bd_intf_pins_external -name S_AXI_HP0 [get_bd_intf_pins ps7/S_AXI_HP0]
  set_property CONFIG.ASSOCIATED_BUSIF {S_AXI_HP0} [get_bd_ports hp0_aclk]

  assign_bd_address
  validate_bd_design
  save_bd_design

  # Synthesize the block design together with the rest of the RTL instead of
  # as a separate out-of-context run, so a plain synth_design sees everything.
  set bd [get_files ps7_bd.bd]
  set_property synth_checkpoint_mode None $bd
  generate_target all $bd
  add_files -norecurse [make_wrapper -files $bd -top]

  set init [glob -nocomplain [file dirname $bd]/ip/*/ps7_init.tcl \
                             [get_property DIRECTORY [current_project]]/*.gen/sources_1/bd/ps7_bd/ip/*/ps7_init.tcl]
  if {[llength $init] == 0} { error "ps7_init.tcl was not generated" }
  return [lindex $init 0]
}
