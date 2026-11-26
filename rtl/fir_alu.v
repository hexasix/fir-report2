`timescale 1ns/1ps
// FIR arithmetic only. The controller supplies sixteen operand pairs per valid
// group, with tags 0, 1, 2, 3 in order for each sample. Bubbles are allowed;
// groups from different samples must not interleave. rstn is local to clk.
module fir_alu #(
`ifdef FIR_ALU_PIPELINED
    parameter integer PIPELINED = 1
`else
    parameter integer PIPELINED = 0
`endif
) (
    input  wire                clk,
    input  wire                rstn,
    input  wire                valid_in,
    input  wire [1:0]          group_in,
    input  wire [255:0]        x_in,
    input  wire [255:0]        b_in,
    output reg                 valid_out,
    output reg signed [15:0]   dout
);
    localparam integer PRODUCT_STAGE = (PIPELINED != 0) ? 2 : 0;
    localparam integer SUM_STAGE = PRODUCT_STAGE + 4 + ((PIPELINED != 0) ? 1 : 0);
    reg [SUM_STAGE:0] group_valid;
    reg [1:0] group_tag [0:SUM_STAGE];
    reg signed [31:0] product [0:15];
    reg signed [32:0] level1 [0:7];
    reg signed [33:0] level2 [0:3];
    reg signed [34:0] level3 [0:1];
    reg signed [35:0] group_sum;
    reg signed [37:0] accumulator, total;
    reg total_valid;

    wire signed [37:0] extended_sum = {{2{group_sum[35]}}, group_sum};
    wire signed [37:0] next_acc = (group_tag[SUM_STAGE] == 2'd0) ?
                                  extended_sum : accumulator + extended_sum;

    // All intermediate values have 30 fractional bits. The low 21 bits are
    // the nonnegative remainder relative to the arithmetic-shift floor.
    function [15:0] quantize_q7_9;
        input signed [37:0] value;
        reg signed [17:0] rounded;
        reg [20:0] remainder;
        begin
            rounded = {value[37], value[37:21]};
            remainder = value[20:0];
            if (remainder > 21'h100000 ||
                (remainder == 21'h100000 && rounded[0]))
                rounded = rounded + 18'sd1;
            if (rounded > 18'sd32767)
                quantize_q7_9 = 16'h7fff;
            else if (rounded < -18'sd32768)
                quantize_q7_9 = 16'h8000;
            else
                quantize_q7_9 = rounded[15:0];
        end
    endfunction

    genvar j;
    generate
        for (j = 0; j < 16; j = j + 1) begin : gen_product
            wire signed [15:0] x = x_in[16*j +: 16];
            wire signed [15:0] b = b_in[16*j +: 16];
            if (PIPELINED != 0) begin : split_product
                wire signed [7:0] x_hi = x[15:8];
                wire signed [7:0] b_hi = b[15:8];
                wire signed [8:0] x_lo = {1'b0, x[7:0]};
                wire signed [8:0] b_lo = {1'b0, b[7:0]};
                reg signed [15:0] hh, hl, lh;
                reg [15:0] ll;
                reg signed [16:0] cross_sum;
                reg [23:0] outer_hi;
                reg [7:0] outer_lo;
                wire [23:0] product_hi = outer_hi + {{7{cross_sum[16]}}, cross_sum};

                // x*b = (hh << 16) + ((hl+lh) << 8) + ll.
                always @(posedge clk or negedge rstn) begin
                    if (!rstn) begin
                        hh <= 0; hl <= 0; lh <= 0; ll <= 0;
                        cross_sum <= 0; outer_hi <= 0; outer_lo <= 0;
                        product[j] <= 0;
                    end else begin
                        if (valid_in) begin
                            hh <= x_hi * b_hi;
                            hl <= x_hi * b_lo;
                            lh <= x_lo * b_hi;
                            ll <= x[7:0] * b[7:0];
                        end
                        if (group_valid[0]) begin
                            cross_sum <= $signed({hl[15], hl}) + $signed({lh[15], lh});
                            outer_hi <= {hh, ll[15:8]};
                            outer_lo <= ll[7:0];
                        end
                        if (group_valid[1]) product[j] <= {product_hi, outer_lo};
                    end
                end
            end else begin : direct_product
                always @(posedge clk or negedge rstn)
                    if (!rstn) product[j] <= 0;
                    else if (valid_in) product[j] <= x * b;
            end
        end
        for (j = 0; j < 8; j = j + 1) begin : gen_level1
            always @(posedge clk or negedge rstn)
                if (!rstn) level1[j] <= 0;
                else if (group_valid[PRODUCT_STAGE])
                    level1[j] <= $signed({product[2*j][31], product[2*j]}) +
                                 $signed({product[2*j+1][31], product[2*j+1]});
        end
        for (j = 0; j < 4; j = j + 1) begin : gen_level2
            always @(posedge clk or negedge rstn)
                if (!rstn) level2[j] <= 0;
                else if (group_valid[PRODUCT_STAGE+1])
                    level2[j] <= $signed({level1[2*j][32], level1[2*j]}) +
                                 $signed({level1[2*j+1][32], level1[2*j+1]});
        end
        for (j = 0; j < 2; j = j + 1) begin : gen_level3
            always @(posedge clk or negedge rstn)
                if (!rstn) level3[j] <= 0;
                else if (group_valid[PRODUCT_STAGE+2])
                    level3[j] <= $signed({level2[2*j][33], level2[2*j]}) +
                                 $signed({level2[2*j+1][33], level2[2*j+1]});
        end
    endgenerate

    wire [35:0] a = {level3[0][34], level3[0]};
    wire [35:0] b = {level3[1][34], level3[1]};
    generate
        if (PIPELINED != 0) begin : split_final_add
            // Compute both carry-in cases locally; select after registering.
            wire [12:0] low = {1'b0, a[11:0]} + {1'b0, b[11:0]};
            wire [12:0] mid = {1'b0, a[23:12]} + {1'b0, b[23:12]};
            reg [11:0] low_sum, mid0, mid1, high0, high1;
            reg carry_low, mid_generate, mid_propagate;
            wire carry_high = mid_generate | (mid_propagate & carry_low);
            always @(posedge clk or negedge rstn) begin
                if (!rstn) begin
                    low_sum <= 0; mid0 <= 0; mid1 <= 0;
                    high0 <= 0; high1 <= 0; carry_low <= 0;
                    mid_generate <= 0; mid_propagate <= 0;
                    group_sum <= 0;
                end else begin
                    if (group_valid[PRODUCT_STAGE+3]) begin
                        low_sum <= low[11:0];
                        mid0 <= mid[11:0];
                        mid1 <= a[23:12] + b[23:12] + 12'd1;
                        high0 <= a[35:24] + b[35:24];
                        high1 <= a[35:24] + b[35:24] + 12'd1;
                        carry_low <= low[12];
                        mid_generate <= mid[12];
                        mid_propagate <= &(a[23:12] ^ b[23:12]);
                    end
                    if (group_valid[PRODUCT_STAGE+4])
                        group_sum <= {carry_high ? high1 : high0,
                                      carry_low ? mid1 : mid0, low_sum};
                end
            end
        end else begin : direct_final_add
            always @(posedge clk or negedge rstn)
                if (!rstn) group_sum <= 0;
                else if (group_valid[PRODUCT_STAGE+3]) group_sum <= a + b;
        end
    endgenerate

    integer k;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            group_valid <= 0;
            for (k = 0; k <= SUM_STAGE; k = k + 1) group_tag[k] <= 0;
            accumulator <= 0;
            total <= 0;
            total_valid <= 0;
            valid_out <= 0;
            dout <= 0;
        end else begin
            group_valid <= {group_valid[SUM_STAGE-1:0], valid_in};
            group_tag[0] <= group_in;
            for (k = 1; k <= SUM_STAGE; k = k + 1) group_tag[k] <= group_tag[k-1];

            total_valid <= group_valid[SUM_STAGE] && group_tag[SUM_STAGE] == 2'd3;
            if (group_valid[SUM_STAGE]) begin
                accumulator <= next_acc;
                if (group_tag[SUM_STAGE] == 2'd3) total <= next_acc;
            end

            valid_out <= total_valid;
            if (total_valid) dout <= quantize_q7_9(total);
        end
    end
endmodule
