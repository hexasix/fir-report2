`timescale 1ns/1ps
// FIR arithmetic only. The controller supplies sixteen operand pairs per valid
// group, with tags 0, 1, 2, 3 in order for each sample. Bubbles are allowed;
// groups from different samples must not interleave. rstn is local to clk.
module fir_alu (
    input  wire                clk,
    input  wire                rstn,
    input  wire                valid_in,
    input  wire [1:0]          group_in,
    input  wire [255:0]        x_in,
    input  wire [255:0]        b_in,
    output reg                 valid_out,
    output reg signed [15:0]   dout
);
    reg [4:0] group_valid;
    reg [1:0] group_tag [0:4];
    reg signed [31:0] product [0:15];
    reg signed [32:0] level1 [0:7];
    reg signed [33:0] level2 [0:3];
    reg signed [34:0] level3 [0:1];
    reg signed [35:0] group_sum;
    reg signed [37:0] accumulator, total;
    reg total_valid;

    wire signed [37:0] extended_sum = {{2{group_sum[35]}}, group_sum};
    wire signed [37:0] next_acc = (group_tag[4] == 2'd0) ?
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
            always @(posedge clk or negedge rstn)
                if (!rstn) product[j] <= 0;
                else if (valid_in) product[j] <= x * b;
        end
        for (j = 0; j < 8; j = j + 1) begin : gen_level1
            always @(posedge clk or negedge rstn)
                if (!rstn) level1[j] <= 0;
                else if (group_valid[0])
                    level1[j] <= $signed({product[2*j][31], product[2*j]}) +
                                 $signed({product[2*j+1][31], product[2*j+1]});
        end
        for (j = 0; j < 4; j = j + 1) begin : gen_level2
            always @(posedge clk or negedge rstn)
                if (!rstn) level2[j] <= 0;
                else if (group_valid[1])
                    level2[j] <= $signed({level1[2*j][32], level1[2*j]}) +
                                 $signed({level1[2*j+1][32], level1[2*j+1]});
        end
        for (j = 0; j < 2; j = j + 1) begin : gen_level3
            always @(posedge clk or negedge rstn)
                if (!rstn) level3[j] <= 0;
                else if (group_valid[2])
                    level3[j] <= $signed({level2[2*j][33], level2[2*j]}) +
                                 $signed({level2[2*j+1][33], level2[2*j+1]});
        end
    endgenerate

    integer k;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            group_valid <= 0;
            for (k = 0; k < 5; k = k + 1) group_tag[k] <= 0;
            group_sum <= 0;
            accumulator <= 0;
            total <= 0;
            total_valid <= 0;
            valid_out <= 0;
            dout <= 0;
        end else begin
            group_valid <= {group_valid[3:0], valid_in};
            group_tag[0] <= group_in;
            for (k = 1; k < 5; k = k + 1) group_tag[k] <= group_tag[k-1];
            if (group_valid[3])
                group_sum <= $signed({level3[0][34], level3[0]}) +
                             $signed({level3[1][34], level3[1]});

            total_valid <= group_valid[4] && group_tag[4] == 2'd3;
            if (group_valid[4]) begin
                accumulator <= next_acc;
                if (group_tag[4] == 2'd3) total <= next_acc;
            end

            valid_out <= total_valid;
            if (total_valid) dout <= quantize_q7_9(total);
        end
    end
endmodule
