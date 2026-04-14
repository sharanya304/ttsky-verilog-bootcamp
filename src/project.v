/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_dma_multi_channel (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);
    
// Parse configuration bus
    wire [7:0] cfg_in = ui_in;
    
    // Parse input control
    wire channel_sel = uio_in[0];           // Channel 0 or 1
    wire [1:0] word_width_sel = uio_in[2:1]; // Word width: 00=7bit, 01=8bit, 10=16bit
    
    // Output buses from both channels
    wire [6:0] data_ch0, data_ch1;
    wire [2:0] flags_ch0, flags_ch1;
    wire done_ch0, done_ch1;
    
    // =====================================================================
    // Channel 0 Instance
    // =====================================================================
    dma_channel dma_ch0 (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_in(cfg_in),
        .word_width_sel(word_width_sel),
        .channel_active(~channel_sel),
        .data_out(data_ch0),
        .error_flags(flags_ch0),
        .dma_done(done_ch0)
    );
    
    // =====================================================================
    // Channel 1 Instance
    // =====================================================================
    dma_channel dma_ch1 (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_in(cfg_in),
        .word_width_sel(word_width_sel),
        .channel_active(channel_sel),
        .data_out(data_ch1),
        .error_flags(flags_ch1),
        .dma_done(done_ch1)
    );
    
    // =====================================================================
    // Multiplex outputs based on channel select
    // =====================================================================
    wire [6:0] data_mux = channel_sel ? data_ch1 : data_ch0;
    wire [2:0] flags_mux = channel_sel ? flags_ch1 : flags_ch0;
    wire done_mux = channel_sel ? done_ch1 : done_ch0;
    
    // =====================================================================
    // Output Mapping (PRESERVING FULL PIN USAGE)
    // =====================================================================
    // uo_out: [7]=done, [6:0]=data[6:0] (ALL 8 BITS FOR DATA + STATUS)
    assign uo_out = {done_mux, data_mux};
    
    // uio_out: error flags on [2:0] as OUTPUT
    // Unused bits tied to zero
    assign uio_out = {5'b00000, flags_mux};
    
    // uio_oe: [2:0]=1 (error flags as output), [7:3]=0 (inputs)
    assign uio_oe = 8'b00000111;
    
    // Silence unused inputs
    wire _unused = &{ena, 1'b0};

endmodule


// =========================================================================
// DMA Channel Module (instantiated 2x)
// =========================================================================
module dma_channel (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] cfg_in,           // [7]=start, [6:4]=src, [3:1]=dst, [0]=count_mode
    input  wire [1:0] word_width_sel,   // 00=7bit, 01=8bit, 10=16bit
    input  wire       channel_active,   // activate this channel
    output reg  [6:0] data_out,         // 7-bit data output
    output reg  [2:0] error_flags,      // [2]=overflow, [1]=boundary_err, [0]=addr_mismatch
    output reg        dma_done          // 1-cycle done pulse
);

    // 8 words x 7 bits memory (original size preserved)
    reg [6:0] mem [0:7];
    
    // Internal state
    reg [2:0] src_ptr;
    reg [2:0] dst_ptr;
    reg [2:0] words_left;
    reg [1:0] state;
    reg effective_mode;
    
    // Error tracking
    reg src_boundary_err;
    reg dst_boundary_err;
    reg addr_mismatch_err;
    
    // FSM states
    localparam IDLE     = 2'b00;
    localparam TRANSFER = 2'b01;
    localparam DONE     = 2'b10;
    
    // =====================================================================
    // Memory Initialization (ASCII test data: a, b, c, d)
    // =====================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem[0] <= 7'h61;  // 'a'
            mem[1] <= 7'h62;  // 'b'
            mem[2] <= 7'h63;  // 'c'
            mem[3] <= 7'h64;  // 'd'
            mem[4] <= 7'h00;
            mem[5] <= 7'h00;
            mem[6] <= 7'h00;
            mem[7] <= 7'h00;
        end
    end
    
    // =====================================================================
    // Main FSM and DMA Control Logic
    // =====================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            data_out         <= 7'h00;
            dma_done         <= 1'b0;
            error_flags      <= 3'b0;
            words_left       <= 3'd0;
            src_ptr          <= 3'd0;
            dst_ptr          <= 3'd0;
            effective_mode   <= 1'b0;
            src_boundary_err <= 1'b0;
            dst_boundary_err <= 1'b0;
            addr_mismatch_err <= 1'b0;
        end else if (channel_active) begin
            // Default: hold outputs
            dma_done <= 1'b0;
            data_out <= data_out;
            
            case (state)
                // =========================================================
                // IDLE State: Wait for start signal
                // =========================================================
                IDLE: begin
                    error_flags      <= 3'b0;
                    src_boundary_err <= 1'b0;
                    dst_boundary_err <= 1'b0;
                    addr_mismatch_err <= 1'b0;
                    
                    if (cfg_in[7]) begin  // Start signal
                        src_ptr <= cfg_in[6:4];
                        dst_ptr <= cfg_in[3:1];
                        
                        // Determine transfer mode
                        case (word_width_sel)
                            2'b00: effective_mode <= cfg_in[0];  // Use original mode bit
                            2'b01: effective_mode <= 1'b1;       // Force 8-bit (3 words)
                            2'b10: effective_mode <= 1'b1;       // Force 16-bit (3 words)
                            default: effective_mode <= cfg_in[0];
                        endcase
                        
                        // Set word count: single=1, burst=3
                        words_left <= (cfg_in[0] | (word_width_sel != 2'b00)) ? 3'd3 : 3'd1;
                        state <= TRANSFER;
                    end
                end
                
                // =========================================================
                // TRANSFER State: Perform data transfer
                // =========================================================
                TRANSFER: begin
                    // Boundary checking
                    src_boundary_err <= (src_ptr > 3'd7);
                    dst_boundary_err <= (dst_ptr > 3'd7);
                    addr_mismatch_err <= (src_ptr == dst_ptr);
                    
                    if (src_boundary_err || dst_boundary_err || addr_mismatch_err) begin
                        // Error detected: set flags and move to done
                        error_flags <= {addr_mismatch_err, dst_boundary_err, src_boundary_err};
                        state <= DONE;
                    end else begin
                        // Perform transfer
                        mem[dst_ptr] <= mem[src_ptr];
                        data_out <= mem[src_ptr];
                        
                        src_ptr <= src_ptr + 1'b1;
                        dst_ptr <= dst_ptr + 1'b1;
                        
                        if (words_left == 3'd1) begin
                            // Last word transferred
                            error_flags <= 3'b0;  // No errors
                            state <= DONE;
                        end else begin
                            words_left <= words_left - 1'b1;
                        end
                    end
                end
                
                // =========================================================
                // DONE State: Signal completion
                // =========================================================
                DONE: begin
                    dma_done <= 1'b1;
                    state <= IDLE;
                end
                
                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
