# =============================================================================
# fpga/zc702/ddr_test/ddr_test.xdc
# =============================================================================
# Pin and timing constraints for ddr_test_top on the ZC702 (xc7z020clg484-1).
# Same PL pins as the earlier milestones (UG850 v1.7). The PS pins (DDR, MIO)
# need no entries here: the PS7 block supplies its own constraints.
# =============================================================================

# 200 MHz LVDS system clock (U43), terminated on the board.
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVDS_25} [get_ports sys_clk_p]
set_property -dict {PACKAGE_PIN C19 IOSTANDARD LVDS_25} [get_ports sys_clk_n]
create_clock -name sys_clk -period 5.000 [get_ports sys_clk_p]

# UART TX on Pmod header J63 pin 1 (PMOD1_0), LED DS19 in parallel.
set_property -dict {PACKAGE_PIN E15 IOSTANDARD LVCMOS25} [get_ports uart_tx_pin]

# LEDs on the PMOD2 nets: DS15 heartbeat, DS16 test running, DS17 failure seen.
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS25} [get_ports led_alive]    ;# PMOD2_3, DS15
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS25} [get_ports led_running]  ;# PMOD2_2, DS16
set_property -dict {PACKAGE_PIN W10 IOSTANDARD LVCMOS25} [get_ports led_fail]     ;# PMOD2_1, DS17

# Reset pushbutton, active high.
set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS25} [get_ports btn_rst]  ;# GPIO_SW_N, SW5 (left)

# Asynchronous or human-speed I/O.
set_false_path -from [get_ports btn_rst]
set_false_path -to [get_ports {uart_tx_pin led_alive led_running led_fail}]

# fclk_reset0_n comes from the PS and only feeds the reset synchronizer's
# asynchronous clear.
set_false_path -through [get_pins -hierarchical -filter {NAME =~ *ps7*/FCLK_RESET0_N}]
