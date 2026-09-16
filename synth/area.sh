#!/usr/bin/env bash
# Quick area/cell-count feedback loop, without waiting ~20 minutes for the GDS CI.
#
#   ./synth/area.sh [verilog-file] [top-module]
#
# Runs yosys in docker against the IHP sg13g2 standard cell library and prints
# the mapped cell count and area. This is synthesis only - it is a good proxy
# for "will it fit", but the real number comes from the LibreLane run in CI,
# which adds clock tree buffers, hold fixing and routing.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTL="${1:-src/tt_um_uart_tx.v}"
TOP="${2:-tt_um_uart_tx}"
CLOCK_PERIOD_NS="${CLOCK_PERIOD_NS:-20}"

LIB_DIR="$REPO/synth/pdk"
LIB="$LIB_DIR/sg13g2_stdcell_typ_1p20V_25C.lib"
LIB_URL="https://raw.githubusercontent.com/IHP-GmbH/IHP-Open-PDK/main/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib"

if [ ! -f "$LIB" ]; then
  echo "fetching sg13g2 liberty..."
  mkdir -p "$LIB_DIR"
  curl -sSL -o "$LIB" "$LIB_URL"
fi

# abc wants the delay target in the liberty's time unit (ns here).
docker run --rm -v "$REPO:/work" -w /work hdlc/yosys:latest yosys -q -p "
  read_verilog -sv $RTL;
  hierarchy -check -top $TOP;
  synth -top $TOP -flatten;
  dfflibmap -liberty synth/pdk/$(basename "$LIB");
  abc -liberty synth/pdk/$(basename "$LIB") -D ${CLOCK_PERIOD_NS}000;
  setundef -zero;
  splitnets;
  opt_clean -purge;
  tee -o synth/area.txt stat -liberty synth/pdk/$(basename "$LIB");
"
echo
echo "--- summary ($RTL, top $TOP, ${CLOCK_PERIOD_NS}ns period) ---"
grep -E "Number of cells|Chip area|Number of wires" synth/area.txt || cat synth/area.txt
