![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Jane Street ASIC design contest - protocol emulator

The design is written in [Hardcaml](https://github.com/janestreet/hardcaml) and
the verilog Tiny Tapeout hardens is generated from it:

```
hardcaml/lib/*.ml --> dune exec bin/generate.exe --> src/tt_um_uart_tx.v --> cocotb + LibreLane -> GDS
```

| path | what it is |
| --- | --- |
| `hardcaml/lib/uart_tx.ml` | the UART transmitter (8N1), parameterised by clock frequency and baud rate |
| `hardcaml/lib/tt_top.ml` | the Tiny Tapeout top level: pin mapping, `rst_n` -> clear, `ena` gating |
| `hardcaml/bin/generate.ml` | writes `src/tt_um_uart_tx.v`, including the `tt_um_*` top level itself |
| `hardcaml/test/` | cyclesim tests that decode the tx pin and print ASCII waveforms |
| `src/tt_um_uart_tx.v` | **generated, do not edit** - checked in so the ASIC flow needs no OCaml |
| `test/` | cocotb tests, run against the generated RTL and the gate level netlist |

Notes: [`verification.md`](verification.md) (what is proved and how),
[`area.md`](area.md) (measured cell costs and the levers that matter),
[`research.md`](research.md) (prior art and papers).

### Working on it

```bash
make rtl         # regenerate src/tt_um_uart_tx.v from hardcaml/
make rtl-check   # fail if the checked in verilog is stale
make hardcaml    # hardcaml simulation tests
make sim         # cocotb tests against the generated verilog
make test        # all of the above
make formal      # bounded proof of the tx timing contract (docker)
make area        # mapped cell count and area on sg13g2 (docker)
```

Retargeting the baud rate or clock is a generator flag, not an RTL edit:

```bash
make rtl CLOCK_HZ=10000000 BAUD=115200
```

Requires an OCaml switch with `hardcaml` (`opam install hardcaml
hardcaml_waveterm`); building the GDS does not.

## Tiny Tapeout template

- [Read the documentation for project](docs/info.md)

## What is Tiny Tapeout?

Tiny Tapeout is an educational project that aims to make it easier and cheaper than ever to get your digital and analog designs manufactured on a real chip.

To learn more and get started, visit https://tinytapeout.com.

## Set up your Verilog project

1. Add your Verilog files to the `src` folder.
2. Edit the [info.yaml](info.yaml) and update information about your project, paying special attention to the `source_files` and `top_module` properties. If you are upgrading an existing Tiny Tapeout project, check out our [online info.yaml migration tool](https://tinytapeout.github.io/tt-yaml-upgrade-tool/).
3. Edit [docs/info.md](docs/info.md) and add a description of your project.
4. Adapt the testbench to your design. See [test/README.md](test/README.md) for more information.

The GitHub action will automatically build the ASIC files using [LibreLane](https://www.zerotoasiccourse.com/terminology/librelane/).

## Enable GitHub actions to build the results page

- [Enabling GitHub Pages](https://tinytapeout.com/faq/#my-github-action-is-failing-on-the-pages-part)

## Resources

- [FAQ](https://tinytapeout.com/faq/)
- [Digital design lessons](https://tinytapeout.com/digital_design/)
- [Learn how semiconductors work](https://tinytapeout.com/siliwiz/)
- [Join the community](https://tinytapeout.com/discord)
- [Build your design locally](https://www.tinytapeout.com/guides/local-hardening/)

## What next?

- [Submit your design to the next shuttle](https://app.tinytapeout.com/).
- Edit [this README](README.md) and explain your design, how it works, and how to test it.
- Share your project on your social network of choice:
  - LinkedIn [#tinytapeout](https://www.linkedin.com/search/results/content/?keywords=%23tinytapeout) [@TinyTapeout](https://www.linkedin.com/company/100708654/)
  - Mastodon [#tinytapeout](https://chaos.social/tags/tinytapeout) [@matthewvenn](https://chaos.social/@matthewvenn)
  - X (formerly Twitter) [#tinytapeout](https://twitter.com/hashtag/tinytapeout) [@tinytapeout](https://twitter.com/tinytapeout)
  - Bluesky [@tinytapeout.com](https://bsky.app/profile/tinytapeout.com)
