# Verifying this design

What is wired up today, what it actually proves, and what to add as the design
grows from a UART into the protocol emulator. Everything here runs locally with
free tools; nothing needs a licence.

Quick reference:

```bash
make hardcaml   # hardcaml cyclesim tests (seconds)
make sim        # cocotb against the generated RTL (seconds)
make formal     # bounded proof of the tx timing contract (~40s, needs docker)
make area       # mapped cell count and area (~40s, needs docker)
make test       # hardcaml + regenerate + staleness check + cocotb
git push        # CI: RTL sim, GDS, precheck, gate level sim (~37 min)
```

## The layers, and what each one is good for

**0. Make the bug impossible.** Hardcaml checks bit widths at circuit
construction, interfaces are records so a port cannot be misconnected silently,
and the Tiny Tapeout top level is generated from the same source as the logic -
so the classic "wrapper and design disagree about a pin" bug has nowhere to
live. Free, and it removes a whole bug class.

**1. Hardcaml cyclesim tests** (`hardcaml/test/`, `make hardcaml`). Fast unit
tests in the same language as the design, with ASCII waveforms. The tx tests
decode the pin back into bytes rather than comparing against a recorded trace,
so they check the protocol, not a golden file. This is where to iterate.

**2. cocotb against the generated verilog** (`test/`, `make sim`). Checks the
artifact the ASIC flow actually consumes. Four tests today: idle level, framing
and bit period over several bytes, strobe-while-busy, `ena` gating. The
testbench reads the clock/baud out of the generated header, so retargeting the
design retargets its tests.

**3. Gate level simulation.** The same cocotb tests run against the post-layout
netlist in CI (`gl_test` job) - it passed on the current design. This is what
catches synthesis and CTS mistakes, and it is free because the tests already
exist. Keep every cocotb test gate-level-clean (no peeking at internal signals)
so this stays true.

**4. Formal: the timing contract** (`formal/`, `make formal`). The interesting
property for a protocol emulator is not "a UART came out" but "the pin changes
exactly when the design says it will, for every input". `formal/uart_tx_formal.sv`
contains an independent reference model of an 8N1 frame and asserts:

- the tx pin equals the reference model at every cycle - framing, bit order and
  bit period, for all 256 data values and all strobe arrival times;
- `busy` is high exactly while a frame is in flight;
- tx only ever changes on a bit boundary.

It passes as a bounded proof (BMC, depth 60, z3, ~37s). The design is generated
at 4 cycles/bit for this so a whole frame fits in the bound; the logic is
identical at the real 434, only the counter is wider. **This is the trick worth
reusing:** because the RTL comes from a parameterised generator, we can prove
properties on a small instance and ship a large one.

Checked that the proof is not vacuous: flipping the bit-period constant in the
generated verilog (`2'b11` -> `2'b10`) makes it fail at step 6 with a
counterexample trace. Do that check whenever you add a property - a proof that
cannot fail is worse than no proof.

**5. Linting.** LibreLane runs verilator lint in CI: currently 0 errors, 6
warnings (5 x COMBDLY - hardcaml emits `<=` inside `always @*` blocks, benign;
1 x UNUSEDSIGNAL for the unused `uio_in[7:1]`). Watch the count rather than the
warnings themselves; a jump means something changed.

## What to add, in the order it will pay off

1. **k-induction, not just BMC.** `mode prove` needs an invariant tying the
   design's `baud_counter`/`state` to the reference model. Once that exists the
   timing contract holds for all time, not just 60 cycles, and it keeps holding
   as the emulator grows.
2. **An OCaml golden model + random programs.** For the emulator core, write the
   ISA semantics as an OCaml function and run random programs through both it
   and cyclesim, comparing pin traces cycle by cycle. This is the single highest
   value test for a programmable chip: it covers instruction interactions that
   no hand written test will reach. Hardcaml has coverage collection
   (`Cyclesim_coverage`) to tell you when the random programs stop finding new
   states.
3. **Protocol monitors as reusable checkers.** A UART/SPI/I2C decoder written
   once as a cocotb monitor becomes both a test oracle and a demo artifact.
   Make them assert timing (setup/hold against the protocol spec), not just
   value.
4. **Netlist fuzzing / equivalence.** We already produce a gate level netlist;
   running random stimulus against RTL *and* netlist and diffing catches
   synthesis bugs a directed test misses. `hardcaml_verify` (installed) has
   `Sec` for sequential equivalence checking and `Sat`/`Nusmv` for
   property checking directly from OCaml, which is the natural home for
   "generated RTL == golden model" style proofs.
5. **Assertions on the emulator's ISA contract.** Once instructions exist:
   "a delay of N cycles takes exactly N cycles regardless of the surrounding
   program" is the property that lets us claim *any* firmware written for the
   chip is timing correct. Prove it once; every protocol inherits it.
6. **LLM-generated assertions as a coverage amplifier, reported honestly.**
   Generate protocol-level SVAs, then mutate the design and report what fraction
   of the generated assertions actually caught each mutation. The ratio is the
   interesting result (see `research.md` for why the literature says the naive
   version overclaims).

## Tooling notes

- Formal: `hdlc/formal:all` docker image - SBY 0.69, yosys 0.36, z3, boolector.
- Synthesis for quick area numbers: `hdlc/yosys` + the IHP liberty, fetched
  automatically by `synth/area.sh`.
- `hardcaml_verify` is installed in the opam switch (`Sat`, `Sec`, `Nusmv`,
  `Cnf`) if we want proofs written in OCaml against the Hardcaml circuit rather
  than SVA against the generated verilog.
- Hardcaml's scope naming survives into the verilog (`state`, `baud_counter`,
  `tx`, `busy` are real net names), so SVA can reference internals when needed -
  use `Scope.naming` deliberately for anything you intend to assert on.
