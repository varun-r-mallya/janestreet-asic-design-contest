(** Tiny Tapeout top level.

    This module has exactly the port list the Tiny Tapeout harness expects, so
    the generated verilog is the project's top level module ([tt_um_*]) - there
    is no hand written wrapper to keep in sync.

    Pinout:
    {v
      ui_in[7:0]   data byte to transmit
      uio_in[0]    start strobe (transmit ui_in while not busy)
      uo_out[0]    uart tx line (idles high)
      uo_out[1]    busy
      uo_out[7:2]  0
      uio_out/oe   0 (all bidirectional pins used as inputs)
    v} *)

open! Core
open Hardcaml
open Hardcaml.Signal

let module_name = "tt_um_uart_tx"

module I = struct
  type 'a t =
    { ui_in : 'a [@bits 8]
    ; uio_in : 'a [@bits 8]
    ; ena : 'a
    ; clk : 'a
    ; rst_n : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { uo_out : 'a [@bits 8]
    ; uio_out : 'a [@bits 8]
    ; uio_oe : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

let create ?config scope (i : Signal.t I.t) =
  let clear = ~:(i.rst_n) in
  (* [ena] is high whenever the design is selected; gating the start strobe with
     it keeps the port used and stops a deselected design from transmitting. *)
  let data_valid = i.uio_in.:(0) &: i.ena in
  let uart =
    Uart_tx.hierarchical
      ?config
      scope
      { Uart_tx.I.clock = i.clk; clear; data = i.ui_in; data_valid }
  in
  { O.uo_out = concat_msb [ zero 6; uart.busy; uart.tx ]
  ; uio_out = zero 8
  ; uio_oe = zero 8
  }
;;

let circuit ?config scope =
  let module C = Circuit.With_interface (I) (O) in
  C.create_exn ~name:module_name (create ?config scope)
;;
