# =============================================================================
# fpga/zc702/zc702.xdc
# =============================================================================
# Pin and timing constraints for fpga_top on the ZC702 (xc7z020clg484-1).
# PL pin assignments are from the ZC702 user guide (UG850 v1.7); all PL banks
# on this board run from VADJ (2.5 V), hence LVCMOS25 / LVDS_25 throughout.
# The PS pins (DDR, MIO) need no entries here: the PS7 block supplies its own
# constraints.
# =============================================================================

# 200 MHz LVDS system clock (U43), terminated on the board. The 50 MHz core
# clock is derived automatically from this through the MMCM.
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVDS_25} [get_ports sys_clk_p]
set_property -dict {PACKAGE_PIN C19 IOSTANDARD LVDS_25} [get_ports sys_clk_n]
create_clock -name sys_clk -period 5.000 [get_ports sys_clk_p]

# UART on Pmod header J63, through the TXS0108E level shifters (3.3 V at the
# header). LEDs DS19 / DS20 are wired in parallel with these two nets.
set_property -dict {PACKAGE_PIN E15 IOSTANDARD LVCMOS25} [get_ports uart_tx_pin]  ;# PMOD1_0, J63.1
set_property -dict {PACKAGE_PIN D15 IOSTANDARD LVCMOS25} [get_ports uart_rx_pin]  ;# PMOD1_1, J63.3

# LEDs on the PMOD2 nets: DS15 heartbeat, DS16 SoC running, DS17 DDR bus error.
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS25} [get_ports led_alive]    ;# PMOD2_3, DS15
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS25} [get_ports led_running]  ;# PMOD2_2, DS16
set_property -dict {PACKAGE_PIN W10 IOSTANDARD LVCMOS25} [get_ports led_error]    ;# PMOD2_1, DS17

# Reset pushbutton, active high (4.7k pull-down on the board).
set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS25} [get_ports btn_rst]  ;# GPIO_SW_N, SW5 (left)

# The button, the UART lines and the LEDs are asynchronous to clk or
# human-speed; btn_rst and uart_rx_pin are resynchronized inside fpga_soc.
set_false_path -from [get_ports {btn_rst uart_rx_pin}]
set_false_path -to [get_ports {uart_tx_pin led_alive led_running led_error}]

# fclk_reset0_n comes from the PS and is resynchronized inside fpga_soc.
set_false_path -through [get_pins -hierarchical -filter {NAME =~ *ps7*/FCLK_RESET0_N}]
