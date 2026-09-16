## How it works

This is the first block of a programmable protocol emulator, and more
importantly it is the *pipeline* the rest of the chip will be built through: the
design is written in [Hardcaml](https://github.com/janestreet/hardcaml) (OCaml),
and the verilog that Tiny Tapeout hardens is generated from it.

```
hardcaml/lib/*.ml  --(dune exec bin/generate.exe)-->  src/tt_um_uart_tx.v  -->  cocotb / LibreLane / GDS
```

The design itself is a UART transmitter. A byte presented on `ui_in` is latched
on a strobe and shifted out of `uo_out[0]` as an 8N1 frame - one low start bit,
eight data bits least significant bit first, one high stop bit - with each bit
held for `clock_hz / baud` cycles. The line idles high and returns high on
reset. `uo_out[1]` is high while a frame is in flight; a strobe during that time
is ignored, so the frame in flight can never be corrupted.

The verilog is generated for 50MHz / 115200 baud (434 cycles per bit). Both
numbers are parameters of the generator, so retargeting is
`make rtl CLOCK_HZ=... BAUD=...` rather than an RTL edit.

The top level module in `src/` is generated too, ports and all - there is no
hand written wrapper that can drift out of sync with the design. The generated
file is checked in, so the GDS flow never needs an OCaml toolchain; `make
rtl-check` fails if it is stale.

## How to test

Two independent testbenches drive the same design:

- `make hardcaml` runs the Hardcaml cyclesim tests (`hardcaml/test/`), which
  decode the tx pin back into bytes and print an ASCII waveform.
- `make sim` runs the cocotb tests (`test/test.py`) against the generated
  verilog, and the same tests run against the gate level netlist in CI. They
  check the idle level, framing and bit period of several bytes, that a strobe
  while busy is ignored, and that nothing is transmitted while `ena` is low.

On hardware: clock the chip at 50MHz, hold `rst_n` low briefly, put a byte on
`ui_in[7:0]`, pulse `uio_in[0]` high for one clock, and read `uo_out[0]` with
any 115200 8N1 serial receiver. `uo_out[1]` shows when the transmitter is busy.

## External hardware

None required. A 3.3V USB-serial adapter on `uo_out[0]` (115200 8N1) is the
easiest way to see the output; a logic analyser works just as well.
