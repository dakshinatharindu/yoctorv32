/* =============================================================================
 * tb/linux_boot/host_stdin.c
 * =============================================================================
 * DPI-C glue so linux_boot_tb.sv can forward live host keystrokes into the
 * simulated UART's RX line without blocking the simulator.
 *
 * Plain SystemVerilog has no non-blocking stdin read ($fgetc always blocks),
 * and Verilator's --timing coroutines only suspend *simulated-time*
 * constructs (#delay, @(posedge clk)) — a genuine blocking OS read() call
 * would stall the whole single-threaded event loop, freezing the clock
 * generator along with everything else until a key is pressed. So instead:
 * put the host terminal in raw/non-blocking mode once at startup (mirrors
 * remu's own host-console handling), then let the SV side poll
 * host_uart_rx_try_read() once per cycle — it always returns immediately.
 *
 * If stdin isn't a real terminal (piped/redirected, or a backgrounded batch
 * run with no tty), host_uart_rx_init() is a no-op and try_read() always
 * returns -1 — existing non-interactive runs are unaffected.
 * =============================================================================
 */

#include <fcntl.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

static struct termios orig_termios;
static int            raw_mode_active = 0;

static void restore_terminal(void) {
  if (raw_mode_active) {
    tcsetattr(STDIN_FILENO, TCSANOW, &orig_termios);
    raw_mode_active = 0;
  }
}

void host_uart_rx_init(void) {
  if (!isatty(STDIN_FILENO)) {
    return;
  }
  if (tcgetattr(STDIN_FILENO, &orig_termios) != 0) {
    return;
  }

  struct termios raw = orig_termios;
  raw.c_lflag &= ~(ICANON | ECHO | ISIG);
  raw.c_cc[VMIN]  = 0;
  raw.c_cc[VTIME] = 0;

  if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0) {
    raw_mode_active = 1;
    atexit(restore_terminal);
  }

  int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
  if (flags != -1) {
    fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
  }
}

/* Returns the next byte typed (0-255), or -1 if none is available. */
int host_uart_rx_try_read(void) {
  unsigned char c;
  ssize_t       n = read(STDIN_FILENO, &c, 1);
  if (n == 1) {
    return (int)c;
  }
  return -1;
}

#ifdef __cplusplus
}
#endif
