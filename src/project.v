/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_spi_master (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

 // uio all inputs, outputs tied to 0
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    // Unused output bits
    assign uo_out[7:4] = 4'b0;

    // ── State encoding using parameters (synthesizable) ──
    parameter ST_IDLE = 2'd0;
    parameter ST_LOAD = 2'd1;
    parameter ST_RUN  = 2'd2;
    parameter ST_DONE = 2'd3;

    reg [1:0]  state;
    reg [3:0]  bit_cnt;     // counts falling edges 0..7
    reg [7:0]  shift_reg;

    reg        mosi_r;
    reg        sclk_r;
    reg        ss_n_r;
    reg        busy_r;

    // Clock divider: SCLK = clk/4
    // sclk_en pulses once every 4 clk cycles when busy
    reg [1:0]  clk_div;
    wire       sclk_en;
    assign     sclk_en = (clk_div == 2'd3);

    assign uo_out[0] = mosi_r;
    assign uo_out[1] = sclk_r;
    assign uo_out[2] = ss_n_r;
    assign uo_out[3] = busy_r;

    // ── Clock divider ─────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            clk_div <= 2'd0;
        else if (busy_r)
            clk_div <= clk_div + 2'd1;
        else
            clk_div <= 2'd0;
    end

    // ── SPI FSM ───────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            mosi_r    <= 1'b0;
            sclk_r    <= 1'b0;
            ss_n_r    <= 1'b1;
            busy_r    <= 1'b0;
            bit_cnt   <= 4'd0;
            shift_reg <= 8'd0;

        end else if (ena) begin
            case (state)

                ST_IDLE: begin
                    sclk_r  <= 1'b0;
                    ss_n_r  <= 1'b1;
                    busy_r  <= 1'b0;
                    mosi_r  <= 1'b0;
                    bit_cnt <= 4'd0;
                    if (uio_in[0]) begin     // start pulse
                        state <= ST_LOAD;
                    end
                end

                ST_LOAD: begin
                    ss_n_r    <= 1'b0;
                    busy_r    <= 1'b1;
                    mosi_r    <= ui_in[7];              // drive MSB
                    shift_reg <= {ui_in[6:0], 1'b0};   // remaining bits
                    bit_cnt   <= 4'd0;
                    sclk_r    <= 1'b0;
                    state     <= ST_RUN;
                end

                ST_RUN: begin
                    if (sclk_en) begin
                        sclk_r <= ~sclk_r;

                        if (!sclk_r) begin
                            // sclk was LOW → going HIGH (rising edge)
                            // Slave samples MOSI here — nothing to change on MOSI
                            // After 8th rising edge (bit_cnt already == 7 from prev fall),
                            // move to DONE on this rising edge
                            if (bit_cnt == 4'd8) begin
                                state <= ST_DONE;
                            end

                        end else begin
                            // sclk was HIGH → going LOW (falling edge)
                            // Master drives next bit
                            bit_cnt <= bit_cnt + 4'd1;
                            if (bit_cnt < 4'd7) begin
                                mosi_r    <= shift_reg[7];
                                shift_reg <= {shift_reg[6:0], 1'b0};
                            end
                            // bit_cnt==7: last falling edge, don't change MOSI
                            // next rising edge (bit_cnt will be 8) triggers DONE
                        end
                    end
                end

                ST_DONE: begin
                    // SCLK is already low, now safely deassert SS
                    sclk_r <= 1'b0;
                    mosi_r <= 1'b0;
                    ss_n_r <= 1'b1;
                    busy_r <= 1'b0;
                    state  <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end

            endcase
        end
    end

endmodule
