/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_test_pattern_gen (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);
     wire [1:0] mode  = ui_in[1:0];
    wire       hold  = ui_in[2];
    wire       srst  = ui_in[3];           // synchronous active-high reset

    wire       reset = srst | ~rst_n;      // combined reset

    // Walking-ones register (8-bit one-hot)
    reg  [7:0] walk_reg;

    // LFSR for PRBS-8  (poly x^8+x^6+x^5+x^4+1)
    reg  [7:0] lfsr;

    // Ramp counter
    reg  [7:0] ramp;

    // Checkerboard toggle
    reg        chk_phase;

    // Output register
    reg  [7:0] pattern;

    // Pattern-done flag: pulses high when pattern wraps
    reg        done;

    // ----------------------------------------------------------------
    // Walking-ones
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            walk_reg <= 8'h01;
        end else if (!hold && mode == 2'b00) begin
            walk_reg <= {walk_reg[6:0], walk_reg[7]};  // rotate left
        end
    end

    // ----------------------------------------------------------------
    // PRBS-8 LFSR  (non-zero seed on reset)
    // ----------------------------------------------------------------
    wire lfsr_feedback = lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3];

    always @(posedge clk) begin
        if (reset) begin
            lfsr <= 8'hFF;
        end else if (!hold && mode == 2'b01) begin
            lfsr <= {lfsr[6:0], lfsr_feedback};
        end
    end

    // ----------------------------------------------------------------
    // Ramp counter 0x00 -> 0xFF
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            ramp <= 8'h00;
        end else if (!hold && mode == 2'b10) begin
            ramp <= ramp + 8'h01;
        end
    end

    // ----------------------------------------------------------------
    // Checkerboard  (alternates 0xAA / 0x55 every clock)
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            chk_phase <= 1'b0;
        end else if (!hold && mode == 2'b11) begin
            chk_phase <= ~chk_phase;
        end
    end

    // ----------------------------------------------------------------
    // Output mux + done flag
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            pattern <= 8'h00;
            done    <= 1'b0;
        end else if (!hold) begin
            case (mode)
                2'b00: begin
                    pattern <= walk_reg;
                    done    <= (walk_reg == 8'h80);    // wrapped when MSB set
                end
                2'b01: begin
                    pattern <= lfsr;
                    done    <= (lfsr == 8'hFF);        // LFSR back to all-ones
                end
                2'b10: begin
                    pattern <= ramp;
                    done    <= (ramp == 8'hFF);        // ramp about to overflow
                end
                2'b11: begin
                    pattern <= chk_phase ? 8'hAA : 8'h55;
                    done    <= chk_phase;              // pulses every other cycle
                end
                default: begin
                    pattern <= 8'h00;
                    done    <= 1'b0;
                end
            endcase
        end
    end

    // ----------------------------------------------------------------
    // Output assignments
    // ----------------------------------------------------------------
    assign uo_out  = pattern;
    assign uio_oe  = 8'hFF;                            // all IOs are outputs
    assign uio_out = {pattern[7:4], 3'b000, done};     // upper nibble + done flag

    // Silence unused inputs (required by TT lint)
    wire _unused = &{ena, uio_in, 1'b0};

endmodule
