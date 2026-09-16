# Area: what things actually cost on this process

All numbers measured on the current design (IHP sg13g2, 6x4 tiles), either from
the LibreLane run in CI or from `make area` (yosys + the sg13g2 liberty, ~40s
locally instead of ~37 minutes in CI).

## Where we stand

| | value |
| --- | --- |
| die (6x4 tiles) | 1289.28 x 710.64 um = **916,214 um^2** |
| core area | 902,417 um^2 |
| UART tx after synthesis (CI) | 184 cells, **2,547 um^2**, 48% of it flip flops |
| UART tx after place & route (CI) | 260 cells, **3,738 um^2** |
| utilisation | **0.41%** of the core |
| setup slack | +12.75 ns at a 20 ns period (slow corner), TNS 0 |
| hold slack | +0.13 ns (fast corner), TNS 0 |
| power | 0.185 mW |

Two things follow immediately. We have ~240x the area of this UART to spend, and
we have enough timing slack to clock roughly 3x faster - so the emulator can
afford to do things *sequentially* (share one datapath across cycles) rather
than in parallel, which is the cheapest kind of area saving there is.

## Unit costs (sg13g2, from the CI synthesis report)

| cell | area um^2 | relative |
| --- | --- | --- |
| `dfrbpq_1` (flip flop) | 48.99 | **1.00** |
| `xnor2_1` | 14.52 | 0.30 |
| `a21oi_1` (AOI) | 9.07 | 0.19 |
| `and2_1` | 9.07 | 0.19 |
| `nand2_1` / `nor2_1` | 7.26 | 0.15 |
| `tiehi` / `tielo` | 7.26 | 0.15 |
| `inv_1` | 5.44 | 0.11 |

**A flip flop costs about seven NAND2s.** State is the currency; combinational
logic is nearly free by comparison. Every architectural decision should be
argued in bits of state, not in gates.

## Levers measured on our UART (and what they were worth)

| change | cells | area um^2 | verdict |
| --- | --- | --- | --- |
| baseline (sync clear, 8-bit shift + 3-bit bit counter) | 131 | 2,217 | - |
| async reset instead of synchronous clear | 120 | 2,215 | **no win** - the reset flop is bigger by exactly what the clear muxes cost |
| sentinel bit in a 9-bit shift register, no bit counter | 133 | 2,170 | -2%, not worth the readability |
| relax the abc target from 20 ns to 100 ns | 131 | 2,217 | **nothing** - the design is not timing limited |

Conclusion for this block: it is flip-flop bound (25 FFs = 1,225 um^2 = 48% of
it), and none of the classic micro-optimisations move it. Stop optimising it;
0.41% of the die is not the problem.

One curiosity worth knowing: 47 of the 184 synthesised cells are tie cells
(341 um^2, 13%) driving the constant outputs - `uio_out`, `uio_oe` and
`uo_out[7:2]`. Tiny Tapeout requires every output to be driven, so unused pins
are never quite free. Irrelevant at scale, but it explains why a "trivial"
design never synthesises to nothing.

## What will actually matter for the emulator

1. **Budget state explicitly.** At 49 um^2 per bit, the whole core is ~11,000
   flip flops if it were nothing but flip flops; at a realistic 60% placement
   density and a normal logic/state mix, plan for **4,000-6,000 bits of state**
   total. That is a lot - four PIO-style state machines with shift registers,
   counters and FIFOs are a few hundred bits - so the budget goes into program
   memory, not the datapath.
2. **Program memory: flip flops are competitive at our size.** Tiny Tapeout's
   RAM32 macro is 401 x 136 um = 54,536 um^2 for 1024 bits, i.e. **~53 um^2 per
   bit** - about the same as a flip flop, because at that size the macro is
   mostly periphery. A 32 x 16 bit program memory in flip flops is 512 bits
   (~25,000 um^2) plus read muxing, and it places anywhere. Rule of thumb from
   these numbers: **below ~1 kbit use flip flops; above a few kbit the larger
   `RM_IHPSG13_1P_1024x32` macro is the one that pays.** Measure before
   committing - this is an estimate from published macro dimensions, not
   something we have synthesised.
3. **Share the timebase.** Each independent baud counter is 9 flip flops. One
   free-running cycle counter that every state machine compares against
   (the PRET `delay_until` model in `research.md`) replaces N counters with one
   counter plus N comparators - and comparators are 0.15 of a flip flop per bit.
   For four state machines that is ~27 flip flops saved, and it makes the timing
   semantics better at the same time.
4. **Trade cycles for area.** With 12.75 ns of slack at 50 MHz we can run a
   bit-serial or time-multiplexed datapath: one shifter serving several state
   machines on alternating cycles costs muxes (cheap) instead of registers
   (expensive).
5. **Narrow the instruction word before widening the memory.** Instruction width
   multiplies through the whole program memory: 32 x 32 bits is 1024 bits, 32 x
   16 is 512. A side-set + delay encoding (RP2040 style) buys back the program
   length that a narrow word costs.
6. **Do not reset what does not need it.** Reset flops cost nothing extra here,
   but a large program memory that is loaded before use needs no reset at all -
   which saves the reset tree and the routing, if not the cell area.

## How to measure

```bash
make area                                   # top of src/, 20 ns target
CLOCK_PERIOD_NS=10 ./synth/area.sh          # tighter target
./synth/area.sh path/to/other.v top_module  # compare a variant
```

`synth/area.sh` runs yosys in docker against the sg13g2 liberty (downloaded on
first use into `synth/pdk/`, gitignored) and prints the cell histogram and area.
It is synthesis only: expect the real number to land ~45% higher after CTS, hold
fixing and buffering (2,547 -> 3,738 um^2 on the current design). Always confirm
a real change in CI.
