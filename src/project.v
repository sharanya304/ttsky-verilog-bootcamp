/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_uart_i2c_bridge (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

// UART timing: 10 MHz / 115200 = 86.8 → round to 87
    parameter [6:0] UART_DIV      = 7'd87;
    parameter [6:0] UART_HALF_DIV = 7'd43;   // mid-bit sample offset

    // I2C timing: 100 kHz SCL from 10 MHz → 50 clocks per half-period
    parameter [5:0] I2C_HALF      = 6'd50;
    parameter [5:0] I2C_QTR       = 6'd25;   // quarter-period (setup/hold)

    // UART frame command codes
    parameter [7:0] CMD_WRITE  = 8'h57;   // ASCII 'W'
    parameter [7:0] CMD_READ   = 8'h52;   // ASCII 'R'

    // UART response codes
    parameter [7:0] RESP_ACK   = 8'hAA;
    parameter [7:0] RESP_NAK   = 8'h4E;   // ASCII 'N'
    parameter [7:0] RESP_ERR   = 8'hFF;   // read failed (no ACK)

    // Top-level FSM states
    parameter [2:0] S_IDLE     = 3'd0;
    parameter [2:0] S_RX_ADDR  = 3'd1;
    parameter [2:0] S_RX_DATA  = 3'd2;
    parameter [2:0] S_I2C_OP   = 3'd3;
    parameter [2:0] S_TX_RESP  = 3'd4;
    parameter [2:0] S_TX_WAIT  = 3'd5;

    // UART-RX FSM states
    parameter [1:0] UR_IDLE    = 2'd0;
    parameter [1:0] UR_START   = 2'd1;
    parameter [1:0] UR_DATA    = 2'd2;
    parameter [1:0] UR_STOP    = 2'd3;

    // UART-TX FSM states
    parameter [1:0] UT_IDLE    = 2'd0;
    parameter [1:0] UT_START   = 2'd1;
    parameter [1:0] UT_DATA    = 2'd2;
    parameter [1:0] UT_STOP    = 2'd3;

    // I2C master FSM states
    parameter [3:0] I2_IDLE      = 4'd0;
    parameter [3:0] I2_START_A   = 4'd1;
    parameter [3:0] I2_START_B   = 4'd2;
    parameter [3:0] I2_SEND_BITS = 4'd3;
    parameter [3:0] I2_ACK1      = 4'd4;
    parameter [3:0] I2_DATA_W    = 4'd5;
    parameter [3:0] I2_ACK2      = 4'd6;
    parameter [3:0] I2_DATA_R    = 4'd7;
    parameter [3:0] I2_NACK      = 4'd8;
    parameter [3:0] I2_STOP_A    = 4'd9;
    parameter [3:0] I2_STOP_B    = 4'd10;
    parameter [3:0] I2_DONE      = 4'd11;

    // =========================================================================
    // I/O assignments — fixed wires
    // =========================================================================
    // UART TX on uo_out[0]; everything else 0
    wire uart_tx_wire;
    assign uo_out = {7'b0, uart_tx_wire};

    // Open-drain SCL on uio[0], SDA on uio[1]; outputs always 0 (OE pulls low)
    assign uio_out = 8'b0;

    reg scl_oe_r, sda_oe_r;
    assign uio_oe  = {6'b0, sda_oe_r, scl_oe_r};

    wire sda_in_w = uio_in[1];   // read SDA from bus

    // =========================================================================
    // UART RX
    // =========================================================================
    wire       uart_rx_in = ui_in[0];

    reg [1:0]  ur_state;
    reg [6:0]  ur_cnt;
    reg [2:0]  ur_bit;
    reg [7:0]  ur_shift;
    reg        ur_done;      // 1-clock pulse: byte received
    reg [7:0]  ur_byte;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ur_state <= UR_IDLE;
            ur_cnt   <= 7'd0;
            ur_bit   <= 3'd0;
            ur_shift <= 8'd0;
            ur_done  <= 1'b0;
            ur_byte  <= 8'd0;
        end else begin
            ur_done <= 1'b0;    // default: clear pulse

            case (ur_state)

                UR_IDLE: begin
                    // Detect start bit (idle=1, start=0)
                    if (!uart_rx_in) begin
                        ur_cnt   <= 7'd0;
                        ur_state <= UR_START;
                    end
                end

                // Wait half a bit-period to land at the centre of the start bit,
                // then move straight to data sampling.
                UR_START: begin
                    if (ur_cnt == UART_HALF_DIV) begin
                        ur_cnt   <= 7'd0;
                        ur_bit   <= 3'd0;
                        ur_state <= UR_DATA;
                    end else begin
                        ur_cnt <= ur_cnt + 7'd1;
                    end
                end

                // Sample one full bit-period after the centre of the previous bit.
                UR_DATA: begin
                    if (ur_cnt == UART_DIV) begin
                        ur_cnt  <= 7'd0;
                        ur_shift <= {uart_rx_in, ur_shift[7:1]};  // LSB-first
                        if (ur_bit == 3'd7) begin
                            ur_state <= UR_STOP;
                        end else begin
                            ur_bit <= ur_bit + 3'd1;
                        end
                    end else begin
                        ur_cnt <= ur_cnt + 7'd1;
                    end
                end

                // Wait through the stop bit, then latch the received byte.
                UR_STOP: begin
                    if (ur_cnt == UART_DIV) begin
                        ur_cnt   <= 7'd0;
                        ur_byte  <= ur_shift;
                        ur_done  <= 1'b1;
                        ur_state <= UR_IDLE;
                    end else begin
                        ur_cnt <= ur_cnt + 7'd1;
                    end
                end

                default: ur_state <= UR_IDLE;

            endcase
        end
    end

    // =========================================================================
    // UART TX
    // =========================================================================
    reg [1:0]  ut_state;
    reg [6:0]  ut_cnt;
    reg [2:0]  ut_bit;
    reg [7:0]  ut_shift;
    reg        ut_busy;
    reg        ut_tx_r;     // the actual TX line register

    assign uart_tx_wire = ut_tx_r;

    // Handshake: top FSM drives ut_req/ut_data; TX clears ut_busy when done.
    reg        ut_req;
    reg [7:0]  ut_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ut_state <= UT_IDLE;
            ut_cnt   <= 7'd0;
            ut_bit   <= 3'd0;
            ut_shift <= 8'd0;
            ut_busy  <= 1'b0;
            ut_tx_r  <= 1'b1;   // idle high
        end else begin

            case (ut_state)

                UT_IDLE: begin
                    ut_tx_r <= 1'b1;
                    if (ut_req && !ut_busy) begin
                        ut_shift <= ut_data;
                        ut_cnt   <= 7'd0;
                        ut_busy  <= 1'b1;
                        ut_tx_r  <= 1'b0;       // start bit
                        ut_state <= UT_START;
                    end
                end

                UT_START: begin
                    if (ut_cnt == UART_DIV) begin
                        ut_cnt   <= 7'd0;
                        ut_bit   <= 3'd0;
                        ut_tx_r  <= ut_shift[0];
                        ut_shift <= {1'b1, ut_shift[7:1]};
                        ut_state <= UT_DATA;
                    end else begin
                        ut_cnt <= ut_cnt + 7'd1;
                    end
                end

                UT_DATA: begin
                    if (ut_cnt == UART_DIV) begin
                        ut_cnt <= 7'd0;
                        if (ut_bit == 3'd7) begin
                            ut_tx_r  <= 1'b1;   // stop bit
                            ut_state <= UT_STOP;
                        end else begin
                            ut_bit   <= ut_bit + 3'd1;
                            ut_tx_r  <= ut_shift[0];
                            ut_shift <= {1'b1, ut_shift[7:1]};
                        end
                    end else begin
                        ut_cnt <= ut_cnt + 7'd1;
                    end
                end

                UT_STOP: begin
                    if (ut_cnt == UART_DIV) begin
                        ut_cnt   <= 7'd0;
                        ut_busy  <= 1'b0;
                        ut_state <= UT_IDLE;
                    end else begin
                        ut_cnt <= ut_cnt + 7'd1;
                    end
                end

                default: ut_state <= UT_IDLE;

            endcase
        end
    end

    // =========================================================================
    // I2C Master
    // =========================================================================
    //
    // Open-drain protocol:
    //   SCL/SDA = 1  →  OE = 0  (let pull-up float the line high)
    //   SCL/SDA = 0  →  OE = 1, OUT = 0  (actively pull low)
    //
    // All bit operations share this rhythm (I2C_HALF low + I2C_HALF high):
    //   cnt=0           : set SCL low (oe=1), drive SDA
    //   cnt=I2C_HALF    : set SCL high (oe=0)
    //   cnt=I2C_HALF+QTR: sample / advance; reset cnt; loop or move state
    //   cnt wraps at 2*I2C_HALF (full period)

    reg [3:0]  i2c_state;
    reg [5:0]  i2c_cnt;
    reg [3:0]  i2c_bit;
    reg [7:0]  i2c_shift;

    // Inputs latched by top FSM before asserting i2c_req
    reg        i2c_req;
    reg        i2c_rw;          // 0=write, 1=read
    reg [7:0]  i2c_addr_byte;   // {addr[6:0], rw}
    reg [7:0]  i2c_wdata;

    // Outputs to top FSM
    reg        i2c_done;
    reg        i2c_ack_ok;
    reg [7:0]  i2c_rdata;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i2c_state  <= I2_IDLE;
            i2c_cnt    <= 6'd0;
            i2c_bit    <= 4'd0;
            i2c_shift  <= 8'd0;
            scl_oe_r   <= 1'b0;
            sda_oe_r   <= 1'b0;
            i2c_done   <= 1'b0;
            i2c_ack_ok <= 1'b0;
            i2c_rdata  <= 8'd0;
        end else begin
            i2c_done <= 1'b0;   // default: clear done pulse

            case (i2c_state)

                // ── Wait for request ────────────────────────────────────────
                I2_IDLE: begin
                    scl_oe_r <= 1'b0;
                    sda_oe_r <= 1'b0;
                    if (i2c_req) begin
                        i2c_cnt    <= 6'd0;
                        i2c_ack_ok <= 1'b1;  // assume ok until a NAK seen
                        i2c_state  <= I2_START_A;
                    end
                end

                // ── START condition: pull SDA low while SCL high ────────────
                // SCL is already high (bus idle). Pull SDA low first.
                I2_START_A: begin
                    sda_oe_r <= 1'b1;   // SDA = 0
                    scl_oe_r <= 1'b0;   // SCL = 1 (released)
                    if (i2c_cnt == I2C_QTR) begin
                        i2c_cnt   <= 6'd0;
                        i2c_state <= I2_START_B;
                    end else begin
                        i2c_cnt <= i2c_cnt + 6'd1;
                    end
                end

                // ── START condition: pull SCL low ───────────────────────────
                I2_START_B: begin
                    scl_oe_r <= 1'b1;   // SCL = 0
                    if (i2c_cnt == I2C_QTR) begin
                        i2c_shift <= i2c_addr_byte;
                        i2c_bit   <= 4'd0;
                        i2c_cnt   <= 6'd0;
                        i2c_state <= I2_SEND_BITS;
                    end else begin
                        i2c_cnt <= i2c_cnt + 6'd1;
                    end
                end

                // ── Generic bit transmitter — used for addr and write-data ──
                // Re-entered with i2c_shift loaded, i2c_bit=0.
                // Sends 8 bits MSB-first, then transitions to ACK state stored
                // in a register (we use i2c_state directly after).
                I2_SEND_BITS: begin
                    // Phase 0..I2C_HALF-1 : SCL low, SDA driven
                    if (i2c_cnt == 6'd0) begin
                        scl_oe_r <= 1'b1;                  // SCL low
                        sda_oe_r <= ~i2c_shift[7];         // drive MSB
                    end
                    // Phase I2C_HALF : SCL high
                    if (i2c_cnt == I2C_HALF) begin
                        scl_oe_r <= 1'b0;
                    end
                    // Phase I2C_HALF+I2C_QTR : advance
                    if (i2c_cnt == (I2C_HALF + I2C_QTR)) begin
                        if (i2c_bit == 4'd7) begin
                            // All 8 bits sent — go to ACK
                            scl_oe_r  <= 1'b1;   // SCL low for ACK bit
                            sda_oe_r  <= 1'b0;   // release SDA for slave ACK
                            i2c_cnt   <= 6'd0;
                            // Next state depends on whether we just sent addr or data
                            // We distinguish by i2c_rw and current address phase:
                            // We use i2c_bit==7 as "finished sending addr_byte" on
                            // first pass, then finished sending wdata on second.
                            // Use a separate 1-bit flag: i2c_phase
                            i2c_state <= I2_ACK1;
                        end else begin
                            i2c_bit   <= i2c_bit + 4'd1;
                            i2c_shift <= {i2c_shift[6:0], 1'b0};
                            i2c_cnt   <= 6'd0;
                            scl_oe_r  <= 1'b1;
                        end
                    end else begin
                        i2c_cnt <= i2c_cnt + 6'd1;
                    end
                end

                // ── ACK slot after address byte ─────────────────────────────
                I2_ACK1: begin
                    sda_oe_r <= 1'b0;              // release SDA
                    // Phase I2C_HALF: SCL high
                    if (i2c_cnt == I2C_HALF) begin
                        scl_oe_r <= 1'b0;
                    end
                    // Phase I2C_HALF+I2C_QTR: sample SDA (ACK = 0)
                    if (i2c_cnt == (I2C_HALF + I2C_QTR)) begin
                        if (sda_in_w)
                            i2c_ack_ok <= 1'b0;  // NAK

                        scl_oe_r  <= 1'b1;       // SCL low
                        i2c_cnt   <= 6'd0;

                        if (!sda_in_w) begin
                            // Slave ACKed — proceed with data phase
                            if (i2c_rw) begin
                                // Read: release SDA, start receiving
                                sda_oe_r  <= 1'b0;
                                i2c_bit   <= 4'd0;
                                i2c_shift <= 8'd0;
                                i2c_state <= I2_DATA_R;
                            end else begin
                                // Write: load data, start sending
                                i2c_shift <= i2c_wdata;
                                i2c_bit   <= 4'd0;
                                i2c_state <= I2_DATA_W;
                            end
                        end else begin
                            // NAK — abort, send STOP
                            i2c_state <= I2_STOP_A;
                        end
                    end else begin
                        i2c_cnt <= i2c_cnt + 6'd1;
                    end
                end

                // ── Transmit write-data byte ─────────────────────────────────
                I2_DATA_W: begin
                    if (i2c_cnt == 6'd0) begin
                        scl_oe_r <= 1'b1;
                        sda_oe_r <= ~i2c_shift[7];
                    end
                    if (i2c_cnt == I2C_HALF) begin
                        scl_oe_r <= 1'b0;
                    end
                    if (i2c_cnt == (I2C_HALF + I2C_QTR)) begin
                        if (i2c_bit == 4'd7) begin
                            scl_oe_r  <= 1'b1;
                            sda_oe_r  <= 1'b0;
                            i2c_cnt   <= 6'd0;
                            i2c_state <= I2_ACK2;
                        end else begin
                            i2c_bit   <= i2c_bit + 4'd1;
                            i2c_shift <= {i2c_shift[6:0], 1'b0};
                            i2c_cnt   <= 6'd0;
                            scl_oe_r  <= 1'b1;
                        end
                    end else begin
                        i2c_cnt <= i2c_cnt + 6'd1;
                    end
                end

                // ── ACK slot after data byte (write) ────────────────────────
                I2_ACK2: begin
                    sda_oe_r <= 1'b0;
                    if (i2c_cnt == I2C_HALF) begin
                        scl_oe_r <= 1'b0;
                    end
                    if (i2c_cnt == (I2C_HALF + I2C_QTR)) begin
                        if (sda_in_w)
                            i2c_ack_ok <= 1'b0;
                        scl_oe_r  <= 1'b1;
                        i2c_cnt   <= 6'd0;
                        i2c_state <= I2_STOP_A;
                    end else begin
                        i2c_cnt <= i2c_cnt + 6'd1;
                    end
                end

                // ── Receive data byte (read) ─────────────────────────────────
                I2_DATA_R: begin
                    sda_oe_r <= 1'b0;    // release SDA — slave drives
                    if (i2c_cnt == I2C_HALF) begin
                        scl_oe_r <= 1'b0;   // SCL high
                    end
                    if (i2c_cnt == (I2C_HALF + I2C_QTR)) begin
                        // Sample SDA at mid-SCL-high
                        i2c_shift <= {i2c_shift[6:0], sda_in_w};
                        scl_oe_r  <= 1'b1;   // SCL low

                        if (i2c_bit == 4'd7) begin
                            i2c_rdata <= {i2c_shift[6:0], sda_in_w};
                            i2c_cnt   <= 6'd0;
                            i2c_state <= I2_NACK;
                        end else begin
                            i2c_bit <= i2c_bit + 4'd1;
                            i2c_cnt <= 6'd0;
                        end
                    end else begin
                        i2c_cnt <= i2c_cnt + 6'd1;
                    end
                end

                // ── Master sends NACK after reading one byte ─────────────────
                // NACK = SDA released (high) during ACK slot.
                I2_NACK: begin
                    sda_oe_r <= 1'b0;    // release = NACK
                    if (i2c_cnt == I2C_HALF) begin
                        scl_oe_r <= 1'b0;
                    end
                    if (i2c_cnt == (I2C_HALF + I2C_QTR)) begin
                        scl_oe_r  <= 1'b1;
                        i2c_cnt   <= 6'd0;
                        i2c_state <= I2_STOP_A;
                    end else begin
                        i2c_cnt <= i2c_cnt + 6'd1;
                    end
                end

                // ── STOP condition, phase A: SCL rises ───────────────────────
                // SDA must be low before SCL rises.
                I2_STOP_A: begin
                    sda_oe_r <= 1'b1;    // hold SDA low
                    scl_oe_r <= 1'b1;    // SCL still low
                    if (i2c_cnt == I2C_QTR) begin
                        scl_oe_r  <= 1'b0;   // release SCL (goes high)
                        i2c_cnt   <= 6'd0;
                        i2c_state <= I2_STOP_B;
                    end else begin
                        i2c_cnt <= i2c_cnt + 6'd1;
                    end
                end

                // ── STOP condition, phase B: SDA rises while SCL high ────────
                I2_STOP_B: begin
                    scl_oe_r <= 1'b0;    // SCL stays high
                    if (i2c_cnt == I2C_QTR) begin
                        sda_oe_r  <= 1'b0;   // release SDA (goes high) → STOP
                        i2c_cnt   <= 6'd0;
                        i2c_state <= I2_DONE;
                    end else begin
                        i2c_cnt <= i2c_cnt + 6'd1;
                    end
                end

                // ── Transaction complete ──────────────────────────────────────
                I2_DONE: begin
                    i2c_done  <= 1'b1;
                    i2c_state <= I2_IDLE;
                end

                default: i2c_state <= I2_IDLE;

            endcase
        end
    end

    // =========================================================================
    // I2C SEND_BITS — address vs. data disambiguation
    // =========================================================================
    // I2_SEND_BITS is a shared state used for both address and data bytes.
    // We solve the "which ACK state to go to" problem by NOT using I2_SEND_BITS
    // for data (I2_DATA_W is a separate, identical copy). The two are kept
    // separate so routing is explicit and the synthesiser never infers latches.
    // (I2_SEND_BITS is therefore used ONLY for the address byte.)
    // The code above already handles this correctly.

    // =========================================================================
    // Top-level control FSM
    // =========================================================================
    reg [2:0]  s_state;
    reg [7:0]  s_cmd;
    reg [7:0]  s_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_state       <= S_IDLE;
            s_cmd         <= 8'd0;
            s_addr        <= 8'd0;
            i2c_req       <= 1'b0;
            i2c_rw        <= 1'b0;
            i2c_addr_byte <= 8'd0;
            i2c_wdata     <= 8'd0;
            ut_req        <= 1'b0;
            ut_data       <= 8'd0;
        end else if (ena) begin
            // Default: deassert one-cycle pulses
            i2c_req <= 1'b0;
            ut_req  <= 1'b0;

            case (s_state)

                // ── Wait for first UART byte (CMD) ──────────────────────────
                S_IDLE: begin
                    if (ur_done) begin
                        s_cmd   <= ur_byte;
                        s_state <= S_RX_ADDR;
                    end
                end

                // ── Wait for second UART byte (ADDR) ────────────────────────
                S_RX_ADDR: begin
                    if (ur_done) begin
                        s_addr  <= ur_byte;
                        s_state <= S_RX_DATA;
                    end
                end

                // ── Wait for third UART byte (DATA), then launch I2C ────────
                S_RX_DATA: begin
                    if (ur_done) begin
                        i2c_rw        <= (s_cmd == CMD_READ) ? 1'b1 : 1'b0;
                        // Compose I2C address byte: addr[7:1] from host, bit0=R/W
                        i2c_addr_byte <= {s_addr[7:1],
                                          (s_cmd == CMD_READ) ? 1'b1 : 1'b0};
                        i2c_wdata     <= ur_byte;
                        i2c_req       <= 1'b1;
                        s_state       <= S_I2C_OP;
                    end
                end

                // ── Wait for I2C transaction to complete ─────────────────────
                S_I2C_OP: begin
                    if (i2c_done) begin
                        // Build response byte
                        if (i2c_rw) begin
                            ut_data <= i2c_ack_ok ? i2c_rdata : RESP_ERR;
                        end else begin
                            ut_data <= i2c_ack_ok ? RESP_ACK  : RESP_NAK;
                        end
                        ut_req  <= 1'b1;
                        s_state <= S_TX_RESP;
                    end
                end

                // ── Kick off UART TX, then wait for it to finish ──────────────
                S_TX_RESP: begin
                    // ut_req was pulsed last cycle; tx picks it up in UT_IDLE.
                    // Now wait until the transmitter is no longer busy.
                    if (!ut_busy) begin
                        s_state <= S_IDLE;
                    end
                end

                default: s_state <= S_IDLE;

            endcase
        end
    end

endmodule

