# Research notes: programmable protocol emulator ASIC

Living notes for the Jane Street ASIC design contest (deadline **2027-01-18**,
IHP 130nm CMOS5L via Tiny Tapeout, **6x4 tiles ~= 0.7mm^2, budget ~1K logic
cells per tile**). The brief: a small CPU whose ISA is built around reading
pins, writing pins, counting cycles and hitting timing exactly, reprogrammable
after fabrication. Start with UART/SPI/I2C; stretch to low-speed USB and 10Mbit
Ethernet.

Each entry is: link, one line on what it is, and **Takeaway** - what it changes
about our design. Add to the end of a section rather than restructuring, and
keep the takeaway line honest (including "probably not useful, here's why").

---

## 1. Prior art: programmable I/O engines

The four commercial designs worth stealing from. All of them solve "arbitrary
protocol in firmware" differently, and the differences are the interesting part.

- **RP2040 PIO** - two blocks, four state machines each, 32 shared instruction
  words, 9 instructions (`JMP WAIT IN OUT PUSH PULL MOV IRQ SET`), each with a
  side-set field and a delay field so one instruction can toggle a pin *and*
  wait N cycles.
  [architecture walkthrough](https://www.cnx-software.com/2021/01/27/a-closer-look-at-raspberry-pi-rp2040-programmable-ios-pio/),
  [MicroPython PIO docs](https://docs.micropython.org/en/latest/rp2/tutorial/pio.html),
  [Cornell design report](https://vanhunteradams.com/6930/Parth_Sharma.pdf).
  **Takeaway:** the delay+side-set encoding is the single highest leverage idea
  for us - it removes most `nop` padding, which is what makes a 32-word program
  memory enough for real protocols. A 24-tile budget probably buys 2-4 state
  machines; the shared-instruction-memory-with-per-SM-PC arrangement is how PIO
  affords more than one.
- **NXP FlexIO** - shifters + timers + pins as composable primitives rather than
  a CPU: load a shifter, assign a timer to clock it, route to a pin.
  [AN5034 emulating UART](https://www.nxp.com/docs/en/application-note/AN5034.pdf),
  [AN13459 PWM](https://www.nxp.com/docs/en/application-note/AN13459.pdf).
  **Takeaway:** the datapath-configuration model is much cheaper in area than an
  instruction fetch/decode loop, but it only covers protocols that factor into
  "shift at a rate". Candidate for a *hybrid*: FlexIO-like shifter/timer
  datapath, PIO-like sequencer driving it. That hybrid is a genuinely novel
  point in the design space and fits the "novel approaches" judging criterion.
- **Cypress/Infineon PSoC UDBs** - datapath + PLD fabric per block; peripherals
  are placed and routed at compile time.
  [PSoC 5LP datasheet](https://www.mouser.com/pdfdocs/PSoC_5LP_CY8C56LP_Family_Datasheet_Programmable_System-on-chip_PSoC_Datasheet-2.pdf).
  **Takeaway:** the PLD half is an FPGA in miniature - too area hungry for 24
  tiles. Their *datapath* block (ALU + shifter + two FIFOs + condition
  generation, sequenced by a small microcode ROM) is the part that scales down.
- **TI PRU** - a full deterministic 32-bit core per I/O subsystem, single cycle
  GPIO.
  [overview](https://zephyrproject.org/increasing-flexibility-software-defined-hardware-interfaces-on-heterogeneous-socs-with-zephyr/).
  **Takeaway:** the "just use a small deterministic CPU" end of the spectrum.
  Most flexible, worst cells-per-protocol; a general purpose ISA spends its area
  on things (wide ALU, register file, memory ops) a protocol emulator barely
  uses.
- **XMOS xCORE / XS1** - hardware multithreading where threads *are* the
  peripherals; ports, timers and channels are architectural, instruction timing
  is statically known, and there is an instruction that dispatches on external
  events.
  [xcore.ai for I/O](https://www.xmos.com/io),
  [architecture background PDF](https://media.futureelectronics.com/semiconductors/microprocessors/embedded-processors/XMOS%20Architecture%20Background.pdf?m=Q4ntpf),
  [XS1 process creation (arXiv 1105.3843)](https://arxiv.org/pdf/1105.3843).
  **Takeaway:** *timed ports* - an output port that latches a value to be driven
  at an absolute future timestamp, and an input port that timestamps a
  transition - are the cleanest answer to "hit timing precisely" and cost far
  less than making the whole core deterministic. Strong candidate primitive.

Still to look at: Parallax Propeller cogs, GreenArrays GA144, ESP32 RMT, Lattice
"hard IP + soft glue" parts, Microchip Core Independent Peripherals (CLC/CCL).

## 2. Timing-precise architectures (academic)

- **PRET / FlexPRET** - RV32I with fine-grained multithreading and *timing
  instructions*: delay-until-absolute-time, wait-for-interrupt-with-timeout,
  schedule-interrupt-at-time. Constant instruction latency, bounded I/O timing
  precision.
  [Zimmer thesis: Predictable Processors ... and Precision-Timed I/O](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2015/EECS-2015-181.html),
  [InterPRET multicore](https://dl.acm.org/doi/fullHtml/10.1145/3576914.3587497),
  [Lingua Franca on time-predictable processors](https://drops.dagstuhl.de/storage/01oasics/oasics-vol128-ng-res2025/OASIcs.NG-RES.2025.1/OASIcs.NG-RES.2025.1.pdf).
  **Takeaway:** the closest academic framing of exactly our problem, and it says
  the win comes from making *time* a first class operand rather than from
  counting cycles by hand. Concretely: a `delay_until` against a free running
  cycle counter makes a protocol's bit period independent of the instruction mix
  in the loop body - which is what makes firmware timing composable. Also the
  right citation to justify the ISA in the writeup.
- **Transport triggered architectures** - program the interconnect, not the
  operations; operations happen as a side effect of moving data to a functional
  unit's trigger port.
  [TTA LDPC/turbo decoder (arXiv 1502.00076)](http://arxiv.org/abs/1502.00076v1).
  **Takeaway:** a TTA-ish encoding is a cheap way to get "this instruction drives
  a pin, starts a shift and bumps a counter" in one word without a wide VLIW
  decoder. Worth a serious look for the instruction encoding.
- **SAILOR** - ultra lightweight RISC-V for IoT, area/energy/security tradeoffs.
  [arXiv 2602.24166](http://arxiv.org/abs/2602.24166v1).
  **Takeaway:** reference numbers for "how small can a usable RV32 core get" if
  we go the PRU route. Compare against SERV (bit-serial RV32I, the smallest
  known) before committing.

## 3. Interface synthesis and protocol conversion (academic)

The 1998-2005 DAC/ICCAD literature on synthesising converters between protocols
described as FSMs. Directly relevant because "protocol as an FSM over pin
events" is exactly our programming model.

- [Passerone, Rowson, Sangiovanni-Vincentelli, *Automatic Synthesis of Interfaces
  between Incompatible Protocols*, DAC 1998](https://www.researchgate.net/publication/2477555_Automatic_Synthesis_of_Interfaces_between_Incompatible_Protocols)
- [de Alfaro, Henzinger, Passerone, Sangiovanni-Vincentelli, *Convertibility
  Verification and Converter Synthesis*, ICCAD 2002](https://cecs.uci.edu/~papers/compendium94-03/papers/2002/iccad02/pdffiles/02b_3.pdf)
- [D'Silva, Sowmya et al., *Automated Interface Synthesis*](https://cgi.cse.unsw.edu.au/~reports/papers/0325.pdf)
  and [*A Formal Approach to Interface Synthesis for SoC*](https://cgi.cse.unsw.edu.au/~reports/papers/0304.pdf)
- [Bhaduri, *Interface Synthesis and Protocol Conversion*](https://www.iitg.ac.in/pbhaduri/papers/interface-synthesis-fac.pdf)
- [*Automatic adaptor synthesis for protocol transformation* (arXiv 1412.0527)](https://arxiv.org/pdf/1412.0527)

**Takeaway:** two uses. (1) A protocol description language: if a protocol is an
FSM with pin guards and timing annotations, our assembler can be a *compiler*
from that description, and the paper's formalism gives us the semantics for
free. (2) Verification: "does this firmware implement the protocol spec" becomes
a refinement check against the same FSM, which is a much stronger claim than "we
simulated a UART and it looked right". This is the thread most likely to make
our verification story distinctive.

## 4. Evidence the stretch goals are reachable

- [Pico-10BASE-T](https://forums.raspberrypi.com/viewtopic.php?t=364138) - 10Mbit
  Ethernet transmit bit-banged from PIO plus a handful of resistors.
- [Pico-100BASE-TX](https://blog.adafruit.com/2025/11/24/pico-100base-tx-rp2040-rp2350-bit-banged-100-mbit-s-ethernet-raspberry_pi/),
  [Elektor writeup](https://www.elektormagazine.com/news/rp2350-bit-bangs-100-mbit-ethernet) -
  100Mbit with MLT-3 + 4B5B + scrambling at a 125MHz symbol rate, PIO + DMA.
- Pico-PIO-USB - low/full speed USB in PIO (2023).

**Takeaway:** all three are *transmit heavy* and lean on (a) a fast symbol clock
and (b) DMA feeding the state machine. For a 24-tile chip with no DRAM and a TT
clock in the tens of MHz, 10BASE-T transmit is plausible (10Mbit needs a 20MHz
Manchester symbol clock) and receive is not, unless we add an oversampling
capture path. Budget the decision early: a "sample pin into a shift register at
full clock rate, with a timestamp" primitive is what makes RX protocols work at
all, and it is cheap.

## 5. Verification (the contest explicitly weights this)

Formal, first:
- [SymbiYosys / sby docs](https://symbiyosys.readthedocs.io/) - the open source
  BMC + k-induction driver over Yosys. Free with our flow.
- [Formal verification of an I2C master with SymbiYosys](https://www.sciencedirect.com/science/article/abs/pii/S0141933126000098) -
  an open source Yosys formal flow applied to an I2C master, covering all FSM
  states and transitions; the paper claims the same assertion infrastructure
  moves to SPI/UART with little change.
- [Assertion-based verification of I2C with SystemVerilog](https://www.mdpi.com/2079-9292/14/8/1687),
  [I2C VIP with error injection](https://www.mdpi.com/2079-9292/14/18/3574).
- [Verifying latency-insensitive designs with formal model checking (arXiv 2102.06326)](https://arxiv.org/pdf/2102.06326).

**Takeaway:** the highest value formal property for us is not "the UART works",
it is *the timing contract*: after `delay_until(t)`, the pin changes at exactly
cycle `t`, for any program. That is a small, bounded, provable property about
the core, and it is what lets us claim every protocol written for the chip is
timing correct rather than just the three we wrote.

LLM-assisted verification (the brief calls this out by name):
- [AssertionBench (arXiv 2406.18627)](http://arxiv.org/abs/2406.18627v2),
  [AssertLLM2 (arXiv 2605.27472)](http://arxiv.org/abs/2605.27472v1),
  [Are LLMs Ready for Practical Adoption for Assertion Generation? (arXiv 2502.20633)](http://arxiv.org/abs/2502.20633v1),
  [SVA dataset (arXiv 2503.08923)](http://arxiv.org/abs/2503.08923v1),
  [Robustness of LLM-generated SVAs to semantics-preserving RTL transformations (arXiv 2609.05658)](http://arxiv.org/abs/2609.05658v1),
  [Learning to Debug: knowledge trees for assertion failures (arXiv 2511.17833)](http://arxiv.org/abs/2511.17833v2).
  **Takeaway:** the honest reading is that LLM-generated assertions are a
  *coverage amplifier*, not an oracle - the robustness paper shows accuracy
  swings with syntactic form. Usable plan: hand-write the timing contract
  properties, LLM-generate the protocol-level ones, and report how many survived
  a mutation/robustness check. Reporting that ratio honestly is more interesting
  to these judges than claiming the assertions were all correct.

Fuzzing and coverage:
- [ProcessorFuzz (arXiv 2209.01789)](http://arxiv.org/abs/2209.01789v1),
  [FuzzWiz (arXiv 2410.17732)](http://arxiv.org/abs/2410.17732v1),
  [SynFuzz - fuzzing the netlist to catch synthesis bugs (arXiv 2504.18812)](http://arxiv.org/abs/2504.18812v3),
  [Logic-solver guided directed fuzzing (arXiv 2509.26509)](http://arxiv.org/abs/2509.26509v1),
  [SoK: ARCUS, efficacy of hardware fuzzing (arXiv 2608.23933)](http://arxiv.org/abs/2608.23933v1).
  **Takeaway:** SynFuzz is the directly actionable one - we already run gate
  level sims in CI, so fuzzing *the netlist against the RTL* is nearly free and
  catches exactly the class of bug (synthesis/CTS) that a tapeout cannot patch.
  For the core, random *programs* (fuzz the ISA, differential against a
  reference model) is the natural instance of processor fuzzing here.
- [Open-Source Verification with Chisel and Scala (arXiv 2102.13460)](http://arxiv.org/abs/2102.13460v1) -
  generator-language verification, the Chisel analogue of what we get from
  Hardcaml cyclesim + OCaml quickcheck.
  **Takeaway:** the argument for writing the reference model in the same language
  as the design. In our flow the golden model for the emulator core should be an
  OCaml function, with the same program run through both it and cyclesim.

## 6. Flow, area and physical design

- [Tiny Tapeout memory spec](https://tinytapeout.com/specs/memory/) - a **RAM32
  macro: 128 bytes (32 words x 32 bits), single read/write port, 401 x 136 um**;
  a larger `RM_IHPSG13_1P_1024x32` macro also exists.
  **Takeaway:** 401x136um is roughly two tiles' worth of our 24 for 32
  instructions of 32 bits. Worth it only if the ISA is wide; a 16-bit
  instruction word doubles the program for the same macro. Decide instruction
  width *after* checking what the macro's aspect ratio does to placement.
- [Tiny Tapeout IHP 26a shuttle](https://tinytapeout.com/chips/ttihp26a/),
  [local hardening guide](https://www.tinytapeout.com/guides/local-hardening/) -
  what the flow expects, and how to run LibreLane without CI.
- [OpenSerDes: open source process-portable all-digital serial link (arXiv 2105.13256)](http://arxiv.org/abs/2105.13256v1)
  **Takeaway:** prior art for doing serial I/O with standard cells only on an
  open PDK - relevant if we ever want to push a link faster than the core clock.
- [NotSoTiny: a living benchmark for RTL code generation (arXiv 2512.20823)](http://arxiv.org/abs/2512.20823v1),
  [ASIC-Agent (arXiv 2508.15940)](http://arxiv.org/abs/2508.15940v1),
  [NL2GDS (arXiv 2603.05489)](http://arxiv.org/abs/2603.05489v1) - agentic
  RTL/GDS flows, several built on Tiny Tapeout.
  **Takeaway:** context for how the judges are likely thinking about AI-assisted
  design; also a source of failure modes to avoid claiming we avoided.

## 7. Where this points (working hypothesis)

1. Architecture: a small number (2-4) of PIO-like sequencers over a shared
   instruction memory, each with side-set + delay in the instruction word, a
   shifter/timer datapath in the FlexIO style, and **timed ports** (XMOS) plus a
   `delay_until` (PRET) against a shared cycle counter as the timing primitives.
2. The differentiator vs PIO: make *time* architectural rather than counted -
   and prove the timing contract formally, so any firmware inherits it.
3. Verification story: OCaml golden model + cyclesim differential testing over
   random programs, formal timing contract in SymbiYosys, LLM-generated protocol
   assertions reported with a robustness ratio, netlist fuzzing against RTL in
   CI (SynFuzz style).
4. Area plan: no SRAM macro until the ISA width is settled; measure cells after
   synthesis on every push (the GDS CI already reports utilisation).

## 8. Open questions

- Instruction width: 16 vs 32 bits, and does side-set+delay fit in 16?
- Do we need an RX capture path (oversampled sampling + timestamp) for I2C
  clock stretching and 10BASE-T receive, and what does it cost?
- How many state machines fit after the shared program memory, FIFOs and pin mux?
- Can `delay_until` semantics survive a shared cycle counter across state
  machines, or does each need its own?
- What does the host interface look like (how does firmware get *in*)? SPI slave
  loader vs shift-in-on-reset vs a few pins of parallel load.
