# =============================================================================
# fpga/zc702/uart_test/uart_test.xdc
# =============================================================================
# Pin and timing constraints for uart_test_top on the ZC702 (xc7z020clg484-1).
# Pin assignments are from the ZC702 user guide (UG850 v1.7). All PL banks on
# this board run from VADJ (2.5 V), hence LVCMOS25 / LVDS_25 throughout.
# =============================================================================

# 200 MHz LVDS system clock (U43). The board has a 100 ohm termination across
# the pair (R168), so DIFF_TERM is not needed.
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVDS_25} [get_ports sys_clk_p]
set_property -dict {PACKAGE_PIN C19 IOSTANDARD LVDS_25} [get_ports sys_clk_n]
create_clock -name sys_clk -period 5.000 [get_ports sys_clk_p]

# UART on Pmod header J63, through the TXS0108E level shifters (3.3 V at the
# header). LEDs DS19 / DS20 are wired in parallel with these two nets.
set_property -dict {PACKAGE_PIN E15 IOSTANDARD LVCMOS25} [get_ports uart_tx_pin]  ;# PMOD1_0, J63.1
set_property -dict {PACKAGE_PIN D15 IOSTANDARD LVCMOS25} [get_ports uart_rx_pin]  ;# PMOD1_1, J63.3

# Heartbeat on PMOD2_3, which drives LED DS15.
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS25} [get_ports led_alive]

# User pushbuttons, active high (4.7k pull-downs on the board).
set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS25} [get_ports btn_rst]   ;# GPIO_SW_N, SW5 (left)
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS25} [get_ports btn_loop]  ;# GPIO_SW_S, SW7 (right)

# Buttons, the UART lines and the LED are asynchronous to clk or human-speed.
set_false_path -from [get_ports {btn_rst btn_loop uart_rx_pin}]
set_false_path -to [get_ports {uart_tx_pin led_alive}]
