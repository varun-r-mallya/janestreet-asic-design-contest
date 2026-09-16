// Formal properties for the hardcaml generated uart_tx.
//
// The design is generated at a small cycles-per-bit (see the Makefile's
// `formal` target) so bounded model checking reaches a whole frame; the logic
// is identical at the real 434 cycles per bit, only the counter is wider.
//
// The interesting property is the timing contract: the tx pin holds each bit
// for exactly CYCLES_PER_BIT cycles, for every data value and every arrival
// time of the start strobe. That is proved here against a reference model, not
// sampled like a simulation does.

`default_nettype none

module uart_tx_formal #(
    parameter int CYCLES_PER_BIT = 4
) (
    input wire clk,
    input wire clear,
    input wire [7:0] data,
    input wire data_valid
);

  localparam int FRAME_CYCLES = 10 * CYCLES_PER_BIT;

  wire tx, busy;

  uart_tx dut (
      .clock(clk),
      .clear(clear),
      .data(data),
      .data_valid(data_valid),
      .tx(tx),
      .busy(busy)
  );

  // Hold the design in reset for the first cycle so the proof starts from the
  // real reset state rather than an arbitrary one.
  reg init_done = 0;
  always @(posedge clk) init_done <= 1;
  always @(*) if (!init_done) assume (clear);
  // `clear` is exercised by the reset assumption above; the properties below
  // describe steady state behaviour.
  always @(*) if (init_done) assume (!clear);

  // ---------------------------------------------------------------------
  // Reference model: an independent description of an 8N1 frame.
  // ---------------------------------------------------------------------
  reg [7:0] captured;
  reg [31:0] frame_cycle;
  reg in_frame;

  initial begin
    captured = 0;
    frame_cycle = 0;
    in_frame = 0;
  end

  always @(posedge clk) begin
    if (clear) begin
      in_frame <= 0;
      frame_cycle <= 0;
    end else if (in_frame) begin
      if (frame_cycle == FRAME_CYCLES - 1) begin
        in_frame <= 0;
        frame_cycle <= 0;
      end else begin
        frame_cycle <= frame_cycle + 1;
      end
    end else if (data_valid) begin
      in_frame <= 1;
      frame_cycle <= 0;
      captured <= data;
    end
  end

  // Which bit of the frame the model expects on the wire right now.
  wire [31:0] bit_number = frame_cycle / CYCLES_PER_BIT;
  wire expected_tx = !in_frame              ? 1'b1              // idle: high
      : (bit_number == 0)   ? 1'b0                              // start bit
      : (bit_number <= 8)   ? captured[bit_number-1]            // data, lsb first
                            : 1'b1;                             // stop bit

  // ---------------------------------------------------------------------
  // Properties
  // ---------------------------------------------------------------------
  always @(posedge clk) begin
    if (init_done) begin
      // 1. The line carries exactly the frame the model describes - this covers
      //    framing, bit order and the bit period, for all 256 data values.
      assert (tx == expected_tx);

      // 2. busy means "a frame is in flight", and nothing else.
      assert (busy == in_frame);

      // 3. The timing contract: tx only ever changes on a bit boundary.
      if ($past(init_done) && tx != $past(tx))
        assert ($past(frame_cycle) % CYCLES_PER_BIT == CYCLES_PER_BIT - 1
                || $past(in_frame) == 0);
    end
  end

  // A liveness-ish cover: a complete frame is reachable.
  always @(posedge clk) cover (init_done && $fell(busy));

endmodule
