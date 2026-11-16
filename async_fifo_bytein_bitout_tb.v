`timescale 1ns / 1ps
module async_fifo_bytein_bitout_tb;
    parameter addr_size    = 3;
    parameter WCLK_PERIOD  = 60;   // write clock period
    parameter RCLK_PERIOD  = 10;   // read clock period

    reg  wclk;
    reg  wrst_n;
    reg  w_en;
    reg  [7:0] wdata;
    reg  rclk;
    reg  rrst_n;
    reg  r_en;

    wire full;
    wire empty;
    wire serial_out;
    wire bit_valid;

    async_fifo_bytein_bitout #(
        .addr_size(addr_size)
    ) dut (
        .wclk      (wclk),
        .wrst_n    (wrst_n),
        .w_en      (w_en),
        .wdata     (wdata),
        .rclk      (rclk),
        .rrst_n    (rrst_n),
        .r_en      (r_en),
        .full      (full),
        .empty     (empty),
        .serial_out(serial_out),
        .bit_valid (bit_valid)
    );

    initial begin
        wclk = 1'b0;
        forever #(WCLK_PERIOD/2) wclk = ~wclk;
    end
    initial begin
        rclk = 1'b0;
        forever #(RCLK_PERIOD/2) rclk = ~rclk;
    end

    reg [7:0] expected_mem [0:12];
    reg [7:0] received_mem [0:12];

    integer write_count;
    integer recv_count;
    integer i;

    reg [7:0] recv_shift;
    reg [2:0] recv_bit_count;

    task write_byte;
        input [7:0] data_in;
        begin
            @(posedge wclk);
            while (full) begin
                $display("[%0t] FIFO FULL, waiting to write 0x%02h", $time, data_in);
                @(posedge wclk);
            end

            w_en  <= 1'b1;
            wdata <= data_in;

            @(posedge wclk);
            w_en  <= 1'b0;
            wdata <= 8'h00;

            expected_mem[write_count] = data_in;
            $display("[%0t] WROTE BYTE[%0d] = 0x%02h (%b)", 
                     $time, write_count, data_in, data_in);
            write_count = write_count + 1;
        end
    endtask

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            recv_shift     <= 8'h00;
            recv_bit_count <= 3'd0;
        end
        else begin
            if (bit_valid) begin
                recv_shift <= {recv_shift[6:0], serial_out};

                if (recv_bit_count == 3'd7) begin
                    received_mem[recv_count] <= {recv_shift[6:0], serial_out};
                    $display("[%0t] RECEIVED BYTE[%0d] = 0x%02h (%b)", 
                             $time, recv_count, {recv_shift[6:0], serial_out}, {recv_shift[6:0], serial_out});
                    recv_count <= recv_count + 1;
                    recv_bit_count <= 3'd0;
                end
                else begin
                    recv_bit_count <= recv_bit_count + 1'b1;
                end
            end
        end
    end

    initial begin
        wrst_n = 1'b0;
        rrst_n = 1'b0;
        w_en   = 1'b0;
        wdata  = 8'h00;
        r_en   = 1'b0;

        write_count = 0;
        recv_count  = 0;
        recv_shift  = 8'h00;
        recv_bit_count = 3'd0;

        for (i = 0; i < 32; i = i + 1) begin
            expected_mem[i] = 8'h00;
            received_mem[i] = 8'h00;
        end

        #25;
        wrst_n = 1'b1;
        rrst_n = 1'b1;

        write_byte(8'hA5);
        write_byte(8'h3C);
        write_byte(8'hF0);
        write_byte(8'h5A);
        write_byte(8'h81);
        write_byte(8'h7E);
        write_byte(8'hB3);
        write_byte(8'h74);
        
        #300
        $display("[%0t] After 8 writes: full = %b, empty = %b", $time, full, empty);
        
        // Now, we are doing blocked write and delayed read enable in parallel, because otherwise, read_enable cannot be reached because the task is blocking
        fork
            begin
                write_byte(8'hD4);
                $display("[%0t] Extra write completed", $time);
            end
            begin
                #200;
                r_en = 1'b1;
                $display("[%0t] Read enabled", $time);
            end
        join
        
        // wait for some time
        #(WCLK_PERIOD * 10);
        
        // to test the simultaneous write and read
        write_byte(8'hC4);
        write_byte(8'hD8);
        
        #(WCLK_PERIOD * 10);

        $display("\n================ COMPARISON ================\n");
        if (recv_count !== write_count) begin
            $display("COUNT MISMATCH: wrote %0d bytes, received %0d bytes", write_count, recv_count);
        end
        else begin
            $display("BYTE COUNT MATCH: %0d bytes", write_count);
        end

        for (i = 0; i < write_count; i = i + 1) begin
            if (received_mem[i] === expected_mem[i]) begin
                $display("BYTE[%0d] PASS: expected = 0x%02h, received = 0x%02h",
                         i, expected_mem[i], received_mem[i]);
            end
            else begin
                $display("BYTE[%0d] FAIL: expected = 0x%02h, received = 0x%02h",
                         i, expected_mem[i], received_mem[i]);
            end
        end

        $display("\n============================================\n");
        $finish;
    end

endmodule
