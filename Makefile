# Hardcaml -> RTL -> Tiny Tapeout pipeline.
#
#   make rtl        regenerate src/tt_um_uart_tx.v from hardcaml/
#   make rtl-check  fail if the checked in verilog is stale
#   make hardcaml   build + run the hardcaml (cyclesim) tests
#   make sim        run the cocotb tests against the generated RTL
#   make test       everything: hardcaml tests, regenerate, rtl-check, cocotb
#   make formal     bounded proof of the tx timing contract (needs docker)
#   make area       mapped cell count + area against the sg13g2 cells (docker)
#
# The generated verilog IS checked in: the Tiny Tapeout GDS flow and the GitHub
# actions only ever see src/, they never need an OCaml toolchain.

HARDCAML_DIR := hardcaml
RTL          := src/tt_um_uart_tx.v
CLOCK_HZ     ?= 50000000
BAUD         ?= 115200

.PHONY: all rtl rtl-check hardcaml sim test formal area clean

all: test

rtl:
	cd $(HARDCAML_DIR) && dune build
	cd $(HARDCAML_DIR) && dune exec bin/generate.exe -- \
		-output-file ../$(RTL) \
		-clock-frequency-hz $(CLOCK_HZ) \
		-baud-rate $(BAUD)

rtl-check:
	cd $(HARDCAML_DIR) && dune build
	cd $(HARDCAML_DIR) && dune exec bin/generate.exe -- \
		-output-file ../$(RTL).check \
		-clock-frequency-hz $(CLOCK_HZ) \
		-baud-rate $(BAUD)
	diff -u $(RTL) $(RTL).check \
		|| (echo "*** $(RTL) is stale - run 'make rtl' ***"; rm -f $(RTL).check; exit 1)
	rm -f $(RTL).check
	@echo "$(RTL) is up to date with $(HARDCAML_DIR)/"

hardcaml:
	cd $(HARDCAML_DIR) && dune runtest

sim:
	$(MAKE) -C test clean
	$(MAKE) -C test
	! grep -q failure test/results.xml

test: hardcaml rtl rtl-check sim

# Formal runs against a deliberately small cycles-per-bit so a whole frame fits
# inside the bounded model checking depth. The logic is the same at 434.
FORMAL_CLOCK_HZ ?= 4000
FORMAL_BAUD     ?= 1000

formal:
	mkdir -p formal/build
	cd $(HARDCAML_DIR) && dune exec bin/generate.exe -- \
		-output-file ../formal/build/uart_tx_small.v \
		-clock-frequency-hz $(FORMAL_CLOCK_HZ) -baud-rate $(FORMAL_BAUD)
	docker run --rm -v "$(CURDIR):/work" -w /work/formal hdlc/formal:all \
		bash -lc "rm -rf uart_tx && sby -f uart_tx.sby"

area:
	./synth/area.sh

clean:
	cd $(HARDCAML_DIR) && dune clean
	$(MAKE) -C test clean
	rm -rf formal/build formal/uart_tx synth/area.txt
