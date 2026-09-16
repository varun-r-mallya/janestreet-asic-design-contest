(** Simulation test for the generated design.

    Drives the Tiny Tapeout pins exactly as the harness does, samples the tx pin
    every clock cycle, and decodes the 8N1 frame back out - so this checks the
    framing and the bit period, not just "something toggled". *)

open! Core
open Hardcaml
open Hardcaml_waveterm
open Tt_protocol_emulator

(* A deliberately slow baud rate so a frame is a handful of cycles and the
   waveform fits on a screen. The real chip is generated with the defaults. *)
let config : Uart_tx.Config.t = { clock_frequency_hz = 1_000_000; baud_rate = 250_000 }
let cycles_per_bit = Uart_tx.Config.cycles_per_bit config

module Sim = Cyclesim.With_interface (Tt_top.I) (Tt_top.O)

let check name ~expect ~got =
  if not (List.equal Int.equal expect got)
  then
    raise_s
      [%message
        "unexpected bytes on the tx pin"
          (name : string)
          (expect : Int.Hex.t list)
          (got : Int.Hex.t list)];
  printf "%s: %s\n" name (Sexp.to_string [%sexp (got : Int.Hex.t list)])
;;

let tx_of_outputs (o : Bits.t ref Tt_top.O.t) = Bits.to_int_trunc !(o.uo_out) land 1
let busy_of_outputs (o : Bits.t ref Tt_top.O.t) = (Bits.to_int_trunc !(o.uo_out) lsr 1) land 1

(* Decode a sampled-per-cycle tx trace as 8N1 at [cycles_per_bit]. Returns the
   bytes seen, and raises if a frame is malformed. *)
let decode (trace : int list) =
  let trace = Array.of_list trace in
  let bytes = ref [] in
  let i = ref 0 in
  while !i + (10 * cycles_per_bit) <= Array.length trace do
    if trace.(!i) = 0
    then (
      let start = !i in
      let sample bit_number =
        (* sample in the middle of each bit period *)
        trace.(start + (bit_number * cycles_per_bit) + (cycles_per_bit / 2))
      in
      if sample 0 <> 0 then raise_s [%message "bad start bit" (start : int)];
      let byte =
        List.init 8 ~f:(fun bit -> sample (bit + 1) lsl bit)
        |> List.fold ~init:0 ~f:( lor )
      in
      if sample 9 <> 1 then raise_s [%message "bad stop bit" (start : int) (byte : int)];
      bytes := byte :: !bytes;
      i := start + (10 * cycles_per_bit))
    else incr i
  done;
  List.rev !bytes
;;

let send sim (i : Bits.t ref Tt_top.I.t) (o : Bits.t ref Tt_top.O.t) ~trace byte =
  i.ui_in := Bits.of_int_trunc ~width:8 byte;
  i.uio_in := Bits.of_int_trunc ~width:8 1;
  Cyclesim.cycle sim;
  trace := tx_of_outputs o :: !trace;
  i.uio_in := Bits.of_int_trunc ~width:8 0;
  (* start bit + 8 data + stop, plus slack for the strobe to be taken *)
  let cycles = (11 * cycles_per_bit) + 4 in
  for _ = 1 to cycles do
    Cyclesim.cycle sim;
    trace := tx_of_outputs o :: !trace
  done
;;

let test_framing () =
  let scope = Scope.create ~flatten_design:true () in
  let sim =
    Sim.create ~config:Cyclesim.Config.trace_all (Tt_top.create ~config scope)
  in
  let waves, sim = Cyclesim.Waveform.create sim in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs sim in
  let trace = ref [] in
  i.ena := Bits.vdd;
  i.rst_n := Bits.gnd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  i.rst_n := Bits.vdd;
  Cyclesim.cycle sim;
  if tx_of_outputs o <> 1 then raise_s [%message "tx does not idle high after reset"];
  if busy_of_outputs o <> 0 then raise_s [%message "busy asserted while idle"];
  List.iter [ 0x5a; 0xa5; 0x00; 0xff ] ~f:(send sim i o ~trace);
  let decoded = decode (List.rev !trace) in
  check "framing" ~expect:[ 0x5a; 0xa5; 0x00; 0xff ] ~got:decoded;
  (* A look at the first frame, to eyeball the bit period. *)
  Waveform.print ~display_width:100 ~display_height:20 ~start_cycle:3 ~wave_width:0 waves
;;

(* Holding the strobe high sends back to back frames: one per idle cycle. *)
let test_strobe_held_high () =
  let scope = Scope.create ~flatten_design:true () in
  let sim = Sim.create (Tt_top.create ~config scope) in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs sim in
  let trace = ref [] in
  i.ena := Bits.vdd;
  i.rst_n := Bits.gnd;
  Cyclesim.cycle sim;
  i.rst_n := Bits.vdd;
  Cyclesim.cycle sim;
  (* Hold the strobe high for the whole run: exactly one byte per idle period. *)
  i.ui_in := Bits.of_int_trunc ~width:8 0x3c;
  i.uio_in := Bits.of_int_trunc ~width:8 1;
  for _ = 1 to 25 * cycles_per_bit do
    Cyclesim.cycle sim;
    trace := tx_of_outputs o :: !trace
  done;
  let decoded = decode (List.rev !trace) in
  check "back to back frames" ~expect:[ 0x3c; 0x3c ] ~got:decoded
;;

let () =
  test_framing ();
  test_strobe_held_high ();
  print_endline "all uart_tx tests passed"
;;
