(** UART transmitter.

    8 data bits, no parity, 1 stop bit (8N1). The line idles high; a byte is
    framed as [start(0)] [d0..d7, lsb first] [stop(1)], each bit held for
    [Config.cycles_per_bit] clock cycles. *)

open! Core
open Hardcaml
open Hardcaml.Signal

module Config = struct
  type t =
    { clock_frequency_hz : int
    ; baud_rate : int
    }
  [@@deriving sexp_of]

  (* The Tiny Tapeout board clock is configurable; 50MHz is a sensible default
     for the ihp-sg13g2 flow and divides to 115200 baud with ~0.1% error. *)
  let default = { clock_frequency_hz = 50_000_000; baud_rate = 115_200 }

  let cycles_per_bit t =
    let cycles = t.clock_frequency_hz / t.baud_rate in
    if cycles < 2
    then
      raise_s
        [%message
          "baud rate is too high for the clock frequency" (t : t) (cycles : int)];
    cycles
  ;;
end

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; data : 'a [@bits 8]
    ; data_valid : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { tx : 'a
    ; busy : 'a
    }
  [@@deriving hardcaml]
end

module State = struct
  type t =
    | Idle
    | Start_bit
    | Data_bits
    | Stop_bit
  [@@deriving compare ~localize, enumerate, sexp_of]
end

let create ?(config = Config.default) (scope : Scope.t) (i : Signal.t I.t) =
  let ( -- ) = Scope.naming scope in
  let cycles_per_bit = Config.cycles_per_bit config in
  let counter_width = num_bits_to_represent (cycles_per_bit - 1) in
  let spec = Reg_spec.create () ~clock:i.clock ~clear:i.clear in
  let open Always in
  let sm = State_machine.create (module State) spec in
  let baud_counter = Variable.reg spec ~width:counter_width in
  let bit_index = Variable.reg spec ~width:3 in
  let shift = Variable.reg spec ~width:8 in
  (* The line idles high, so the output register clears to 1. *)
  let tx = Variable.reg spec ~clear_to:vdd ~width:1 in
  let bit_done = baud_counter.value ==:. cycles_per_bit - 1 in
  ignore (sm.current -- "state" : Signal.t);
  ignore (baud_counter.value -- "baud_counter" : Signal.t);
  compile
    [ sm.switch
        [ ( Idle
          , [ when_
                i.data_valid
                [ shift <-- i.data
                ; bit_index <--. 0
                ; baud_counter <--. 0
                ; tx <-- gnd (* start bit *)
                ; sm.set_next Start_bit
                ]
            ] )
        ; ( Start_bit
          , [ if_
                bit_done
                [ baud_counter <--. 0
                ; tx <-- lsb shift.value (* first data bit *)
                ; sm.set_next Data_bits
                ]
                [ incr baud_counter ]
            ] )
        ; ( Data_bits
          , [ if_
                bit_done
                [ baud_counter <--. 0
                ; shift <-- srl shift.value ~by:1
                ; if_
                    (bit_index.value ==:. 7)
                    [ tx <-- vdd (* stop bit *); sm.set_next Stop_bit ]
                    [ incr bit_index; tx <-- shift.value.:(1) ]
                ]
                [ incr baud_counter ]
            ] )
        ; ( Stop_bit
          , [ if_
                bit_done
                [ baud_counter <--. 0; sm.set_next Idle ]
                [ incr baud_counter ]
            ] )
        ]
    ];
  { O.tx = tx.value -- "tx"; busy = ~:(sm.is Idle) -- "busy" }
;;

let hierarchical ?config scope input =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~name:"uart_tx" ~scope (create ?config) input
;;
