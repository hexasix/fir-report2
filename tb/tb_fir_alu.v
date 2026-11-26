`timescale 1ns/1ps
module tb_fir_alu;
    parameter CLK_PERIOD_NS = 2.0;
    parameter integer RANDOM_SAMPLES = 10000;
    parameter integer LAST_GROUP_LATENCY = 6;
    localparam signed [63:0] SCALE = 64'sd2097152;

    reg clk = 0, rstn = 1;
    reg valid_in = 0;
    reg [1:0] group_in = 0;
    reg [255:0] x_in = 0, b_in = 0;
    wire valid_out;
    wire signed [15:0] dout;
    fir_alu dut (.clk(clk), .rstn(rstn), .valid_in(valid_in), .group_in(group_in),
                 .x_in(x_in), .b_in(b_in), .valid_out(valid_out), .dout(dout));
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    reg [31:0] seed, rng;
    integer cycle = 0, checked = 0, completed = 0, flushed = 0, partial_resets = 0;
    integer expected_tag = 0;
    integer phase = 0, seen_phase = 0, last_output_cycle = 0;
    reg signed [63:0] ref_sum;
    reg signed [15:0] expected_data [0:LAST_GROUP_LATENCY];
    reg [LAST_GROUP_LATENCY:0] expected_valid = 0;
    reg signed [15:0] last_dout;
    integer k, n, g, lane, gaps, before_random;
    reg [255:0] x_vec, b_vec;
    real check_delay_ns = 0.050;
    integer power_samples;

    // Reference uses nearest rounding on the magnitude (not the RTL's
    // arithmetic shift/floor) before restoring the sign and clipping.
    function signed [15:0] reference_q7_9;
        input signed [63:0] a;
        reg signed [63:0] magnitude, q, r;
        begin
            magnitude = a < 0 ? -a : a;
            q = magnitude / SCALE;
            r = magnitude % SCALE;
            if (2*r > SCALE || (2*r == SCALE && q[0])) q = q + 1;
            if (a < 0) q = -q;
            if (q > 32767) reference_q7_9 = 16'sh7fff;
            else if (q < -32768) reference_q7_9 = 16'sh8000;
            else reference_q7_9 = q[15:0];
        end
    endfunction

    // Pin-level scoreboard: a sequential sum over scalar products, with a
    // separate queue for result arrival edges. No hierarchical DUT probes.
    function signed [63:0] dot16;
        input [255:0] xs, bs;
        reg signed [63:0] x, b, sum;
        integer i;
        begin
            sum = 0;
            for (i = 0; i < 16; i = i + 1) begin
                x = {{48{xs[16*i+15]}}, xs[16*i +: 16]};
                b = {{48{bs[16*i+15]}}, bs[16*i +: 16]};
                sum = sum + x*b;
            end
            dot16 = sum;
        end
    endfunction

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            // Slot LAST_GROUP_LATENCY was already checked at its edge.
            for (k = 0; k < LAST_GROUP_LATENCY; k = k + 1)
                if (expected_valid[k]) flushed = flushed + 1;
            if (expected_tag != 0) partial_resets = partial_resets + 1;
            expected_valid = 0;
            expected_tag = 0;
            ref_sum = 0;
            last_dout = 0;
            last_output_cycle = 0;
            #(check_delay_ns);
            if (valid_out !== 1'b0 || dout !== 16'sd0)
                $fatal(1, "Output did not reset");
        end else begin
            cycle = cycle + 1;
            if (seen_phase != phase) begin
                seen_phase = phase;
                last_output_cycle = 0;
            end
            expected_valid = {expected_valid[LAST_GROUP_LATENCY-1:0], 1'b0};
            for (k = LAST_GROUP_LATENCY; k > 0; k = k - 1)
                expected_data[k] = expected_data[k-1];
            if (valid_in) begin
                if (group_in !== expected_tag[1:0])
                    $fatal(1, "Stimulus protocol violation at cycle %0d", cycle);
                if (expected_tag == 0) ref_sum = 0;
                ref_sum = ref_sum + dot16(x_in, b_in);
                if (expected_tag == 3) begin
                    expected_data[0] = reference_q7_9(ref_sum);
                    expected_valid[0] = 1;
                    completed = completed + 1;
                    expected_tag = 0;
                end else expected_tag = expected_tag + 1;
            end
            #(check_delay_ns);
            if (valid_out !== expected_valid[LAST_GROUP_LATENCY])
                $fatal(1, "Cycle %0d: expected valid=%b, got %b",
                       cycle, expected_valid[LAST_GROUP_LATENCY], valid_out);
            if (valid_out) begin
                if (dout !== expected_data[LAST_GROUP_LATENCY])
                    $fatal(1, "Cycle %0d output %0d: expected %0d, got %0d",
                           cycle, checked, expected_data[LAST_GROUP_LATENCY], dout);
                if (last_output_cycle != 0 && phase == 1 && cycle-last_output_cycle != 5)
                    $fatal(1, "Report 1 schedule: output spacing must be 5 cycles");
                if (last_output_cycle != 0 && phase == 2 && cycle-last_output_cycle != 4)
                    $fatal(1, "Back-to-back groups: output spacing must be 4 cycles");
                last_output_cycle = cycle;
                last_dout = dout;
                checked = checked + 1;
            end else if (dout !== last_dout)
                $fatal(1, "Output register changed while valid_out was low");
        end
    end

    function [31:0] next_random;
        input [31:0] x;
        reg [31:0] t;
        begin
            t = x ^ (x << 13);
            t = t ^ (t >> 17);
            next_random = t ^ (t << 5);
        end
    endfunction

    task drive_group;
        input valid;
        input [1:0] tag;
        input [255:0] xs, bs;
        begin
            @(negedge clk);
            valid_in = valid; group_in = tag; x_in = xs; b_in = bs;
        end
    endtask

    task bubble;
        begin
            // Deliberately vary tag and operands while invalid.
            rng = next_random(rng);
            drive_group(0, rng[1:0], {8{rng}}, {8{~rng}});
        end
    endtask

    task random_group;
        input [1:0] tag;
        integer i;
        reg [255:0] xs, bs;
        begin
            for (i = 0; i < 16; i = i + 1) begin
                rng = next_random(rng); xs[16*i +: 16] = rng[15:0];
                rng = next_random(rng); bs[16*i +: 16] = rng[15:0];
            end
            drive_group(1, tag, xs, bs);
        end
    endtask

    task pulse_reset;
        begin
            @(negedge clk);
            #0.2;
            rstn = 0; valid_in = 0;
            repeat (3) @(negedge clk);
            rstn = 1;
        end
    endtask

    task directed_sparse;
        input [5:0] tap;
        input signed [15:0] x, b, delta;
        input signed [15:0] known_output;
        reg [255:0] xs, bs;
        integer i;
        begin
            for (i = 0; i < 4; i = i + 1) begin
                xs = 0; bs = 0;
                if (i[1:0] == tap[5:4]) begin
                    xs[16*tap[3:0] +: 16] = x;
                    bs[16*tap[3:0] +: 16] = b;
                    // Optional one-product offset on a different lane.
                    xs[16*(tap[3:0] ^ 4'd1) +: 16] = 16'sd1;
                    bs[16*(tap[3:0] ^ 4'd1) +: 16] = delta;
                end
                drive_group(1, i[1:0], xs, bs);
            end
            repeat (LAST_GROUP_LATENCY + 1) bubble;
            // The scoreboard checks the exact edge, and dout holds afterward.
            if (dout !== known_output)
                $fatal(1, "Directed tap %0d: expected %0d, got %0d", tap, known_output, dout);
        end
    endtask

    // A steady FIR stream for activity estimation: fixed coefficients, a
    // sliding input window, and four valid groups per five clock edges.
    task run_power;
        input integer sample_count;
        reg [15:0] history [0:63];
        reg [15:0] coef [0:63];
        reg [255:0] xs, bs;
        integer i, s, group_id;
        begin
            if (sample_count < 1) $fatal(1, "POWER_SAMPLES must be positive");
            for (i = 0; i < 64; i = i + 1) begin
                rng = next_random(rng); coef[i] = rng[15:0]; history[i] = 0;
            end
            phase = 1;
            for (s = 0; s < sample_count + 64; s = s + 1) begin
                // The history and arithmetic pipeline have filled before capture.
                if (s == 64) begin
                    $dumpfile("fir_alu.vcd");
                    $dumpvars(0, dut);
                end
                for (i = 63; i > 0; i = i - 1) history[i] = history[i-1];
                rng = next_random(rng); history[0] = rng[15:0];
                for (group_id = 0; group_id < 4; group_id = group_id + 1) begin
                    for (i = 0; i < 16; i = i + 1) begin
                        xs[16*i +: 16] = history[16*group_id+i];
                        bs[16*i +: 16] = coef[16*group_id+i];
                    end
                    drive_group(1, group_id[1:0], xs, bs);
                end
                drive_group(0, 2'd3, xs, bs);
            end
            // Stop capture without a $dumpoff X burst. A few drain edges are
            // negligible for the default 10,000-sample activity run.
            repeat (LAST_GROUP_LATENCY + 2) @(negedge clk);
            if (checked != sample_count + 64 || expected_valid != 0)
                $fatal(1, "Activity regression output count mismatch: %0d", checked);
            $display("PASS: activity stream checked %0d outputs; %0d captured inputs; seed=%08h",
                     checked, sample_count, seed);
        end
    endtask

    initial begin : run_tests
        if (RANDOM_SAMPLES < 3) $fatal(1, "Use at least three random samples");
        if ($value$plusargs("CHECK_DELAY_NS=%f", check_delay_ns)) begin
            if (check_delay_ns <= 0 || check_delay_ns >= CLK_PERIOD_NS/2.0)
                $fatal(1, "Choose 0 < CHECK_DELAY_NS < half a clock period");
        end
        if (!$value$plusargs("SEED=%h", seed)) seed = 32'h48230002;
        if (seed == 0) $fatal(1, "xorshift32 needs a nonzero seed");
        rng = seed;
        if ($test$plusargs("vcd") && !$test$plusargs("power")) begin
            $dumpfile("fir_alu.vcd");
            $dumpvars(0, dut);
        end
        #0.2;
        rstn = 0;
        pulse_reset;
        if ($test$plusargs("power")) begin
            if (!$value$plusargs("POWER_SAMPLES=%d", power_samples)) power_samples = 10000;
            run_power(power_samples);
            $finish;
            disable run_tests;
        end
        // Each of the 64 tap positions reaches the output independently.
        for (lane = 0; lane < 64; lane = lane + 1)
            directed_sparse(lane[5:0], 16'sd16384, -16'sd16384, 16'sd0, -16'sd128);
        // Half-LSB ties of both signs and parity, plus one raw unit on either side.
        directed_sparse(6'd0, 16'sd1024, 16'sd1024, 16'sd0, 16'sd0);
        directed_sparse(6'd63, 16'sd1024, 16'sd3072, 16'sd0, 16'sd2);
        directed_sparse(6'd16, 16'sd1024, -16'sd1024, 16'sd0, 16'sd0);
        directed_sparse(6'd47, 16'sd1024, -16'sd3072, 16'sd0, -16'sd2);
        directed_sparse(6'd34, 16'sd1024, 16'sd1024, -16'sd1, 16'sd0);
        directed_sparse(6'd34, 16'sd1024, 16'sd1024, 16'sd1, 16'sd1);
        directed_sparse(6'd34, 16'sd1024, -16'sd1024, -16'sd1, -16'sd1);
        directed_sparse(6'd34, 16'sd1024, -16'sd1024, 16'sd1, 16'sd0);
        // Full-scale positive saturation (+64) and largest negative magnitude.
        for (g = 0; g < 4; g = g + 1)
            drive_group(1, g[1:0], {16{16'h8000}}, {16{16'h8000}});
        repeat (LAST_GROUP_LATENCY + 1) bubble;
        if (dout !== 16'sh7fff) $fatal(1, "Positive saturation failed");
        for (g = 0; g < 4; g = g + 1)
            drive_group(1, g[1:0], {16{16'h8000}}, {16{16'h7fff}});
        repeat (LAST_GROUP_LATENCY + 1) bubble;
        if (dout !== -16'sd32767) $fatal(1, "Negative extreme failed");
        // Mixed products cancel exactly within each adder tree.
        x_vec = {16{16'h8000}};
        b_vec = {8{16'h2000, 16'he000}};
        for (g = 0; g < 4; g = g + 1) drive_group(1, g[1:0], x_vec, b_vec);
        repeat (LAST_GROUP_LATENCY + 1) bubble;
        if (dout !== 16'sd0) $fatal(1, "Exact cancellation failed");

        // Reset cancels a pending result and an in-flight partial sample.
        for (g = 0; g < 4; g = g + 1) random_group(g[1:0]);
        random_group(2'd0);
        random_group(2'd1);
        pulse_reset;
        repeat (LAST_GROUP_LATENCY + 1) bubble;
        // Reset also clears a partial sum that has reached the accumulator.
        random_group(2'd0);
        random_group(2'd1);
        repeat (LAST_GROUP_LATENCY + 1) bubble;
        pulse_reset;
        repeat (LAST_GROUP_LATENCY + 1) bubble;
        if (flushed != 1 || partial_resets != 2)
            $fatal(1, "Reset coverage: flushed=%0d partial=%0d", flushed, partial_resets);

        before_random = checked;
        for (n = 0; n < RANDOM_SAMPLES; n = n + 1) begin
            if (n == 0 || n == RANDOM_SAMPLES/2 || n == 3*RANDOM_SAMPLES/4) begin
                // Finish the previous phase before switching spacing checks.
                repeat (LAST_GROUP_LATENCY + 1) bubble;
                phase = (n == 0) ? 1 : (n == RANDOM_SAMPLES/2) ? 2 : 3;
            end
            for (g = 0; g < 4; g = g + 1) begin
                if (phase == 3) begin
                    rng = next_random(rng);
                    gaps = {30'b0, rng[1:0]};
                    repeat (gaps) bubble;
                end
                random_group(g[1:0]);
            end
            if (phase == 1) bubble;
        end
        repeat (LAST_GROUP_LATENCY + 2) bubble;
        if (expected_tag != 0 || expected_valid != 0 || checked != completed-flushed ||
            checked-before_random != RANDOM_SAMPLES || before_random != 75)
            $fatal(1, "Counts: checked=%0d completed=%0d flushed=%0d directed=%0d random=%0d",
                   checked, completed, flushed, before_random, checked-before_random);
        $display("PASS: %0d directed + %0d randomized outputs; seed=%08h; reset flushed %0d pending result",
                 before_random, checked-before_random, seed, flushed);
        $finish;
    end
endmodule
