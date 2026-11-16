# Asynchronous FIFO with UVM verification

An 8-entry, 8-bit-wide asynchronous (dual-clock) FIFO in Verilog, in two variants that share the same core, each with its own testbench. Both testbenches pass in Vivado XSim (2026.1).

| File | Contents |
|---|---|
| `async_fifo.v` | Both top modules and all sub-modules |
| `async_fifo_bytein_bitout_tb.v` | Directed Verilog testbench for `async_fifo_bytein_bitout` |
| `async_fifo_bytein_byteout_uvm.sv` | UVM testbench for `async_fifo_bytein_byteout` |

## Top modules

**`async_fifo_bytein_byteout`** writes a byte on `wclk` when `w_en` is high and the FIFO is not `full`. On the read side, `rdata` always shows the oldest unread byte, and `r_en` moves on to the next one on `rclk` when the FIFO is not `empty`. Each clock domain has its own active-low asynchronous reset.

**`async_fifo_bytein_bitout`** is the same FIFO with a serializer (`serializer_bit_out_fifo`) on the read side. While `r_en` is high it fetches one byte at a time and shifts it out MSB-first on `serial_out`, one bit per `rclk`, with `bit_valid` marking each valid bit.

## Shared sub-modules

| Module | Role |
|---|---|
| `dual_port_fifo` | The 8x8 memory: written on `wclk`, read combinationally |
| `write_pointer_fifo` | Write pointer in binary and Gray code; advances on a write when not full |
| `read_pointer_fifo` | Read pointer in binary and Gray code; advances on a read when not empty |
| `sync_gray_to_wclk_fifo` | Two-flip-flop synchronizer bringing the Gray read pointer into the `wclk` domain |
| `sync_gray_to_rclk_fifo` | Two-flip-flop synchronizer bringing the Gray write pointer into the `rclk` domain |
| `full_check_fifo` | Registered `full` flag, from the next write pointer and the synchronized read pointer |
| `empty_check_fifo` | `empty` flag: read pointer equals the synchronized write pointer |

## Testbenches

**Directed testbench (`async_fifo_bytein_bitout_tb.v`).** Runs the bit-out FIFO with a 60 ns write clock and a 10 ns read clock. It fills the FIFO with 8 bytes and checks `full`, attempts a 9th write that must stall until reading starts, then writes two more bytes while the serializer is running. A receiver rebuilds bytes from `serial_out` and `bit_valid`, and at the end all 11 bytes are compared with what was written, with a PASS/FAIL line per byte.

**UVM testbench (`async_fifo_bytein_byteout_uvm.sv`).** Drives the byte-out FIFO with a write agent and a read agent that step through the test in lockstep. It runs five rounds, each with a different read clock (slower than, faster than, and close to the 48 ns write clock). Every round resets both domains, does a single write and read, fills the FIFO to `full` and drains it to `empty`, and finishes with a long back-pressured burst. A monitor checks every byte read against a reference queue in the scoreboard (485 bytes in total), and the sequences check the `full` and `empty` flags at each step.
