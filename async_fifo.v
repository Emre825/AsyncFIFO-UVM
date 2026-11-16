`timescale 1ns / 1ps
// Byte-in / byte-out asynchronous FIFO: memory, pointers, synchronizers and flags.
// Verified by the UVM testbench (async_fifo_bytein_byteout_uvm.sv).
module async_fifo_bytein_byteout
 #( parameter addr_size = 3 )
 (
 input wire wclk,
 input wire wrst_n,
 input wire w_en,
 input wire[7:0] wdata,
 input wire rclk,
 input wire rrst_n,
 input wire r_en,
 output wire[7:0] rdata,
 output wire full,
 output wire empty );

 // Internal pointer/address wires
 wire[addr_size:0] wptr_binary;
 wire[addr_size:0] wptr_gray;
 wire[addr_size:0] rptr_binary;
 wire[addr_size:0] rptr_gray;
 wire[addr_size-1:0] waddr;
 wire[addr_size-1:0] raddr;

 // Cross-domain synchronized pointers
 wire[addr_size:0] wptr_gray_sync;
 wire[addr_size:0] rptr_gray_sync;

 // Internal control
 wire fifo_wr_en_safe;
 assign fifo_wr_en_safe = w_en && !full;

 // FIFO memory
 dual_port_fifo u_dual_port_fifo (
 .wclk (wclk),
 .we (fifo_wr_en_safe),
 .waddr (waddr),
 .wdata (wdata),
 .raddr (raddr),
 .rdata (rdata)
 );

 // Write-side logic
 write_pointer_fifo #( .addr_size(addr_size) ) u_write_pointer_fifo (
 .wclk (wclk),
 .wrst_n (wrst_n),
 .w_en (w_en),
 .full (full),
 .wptr_binary (wptr_binary),
 .wptr_gray (wptr_gray),
 .waddr (waddr) );

 sync_gray_to_wclk_fifo #( .addr_size(addr_size) ) u_sync_gray_to_wclk_fifo (
 .wclk (wclk),
 .wrst_n (wrst_n),
 .rptr_gray (rptr_gray),
 .rptr_gray_sync(rptr_gray_sync) );

 full_check_fifo #( .addr_size(addr_size) ) u_full_check_fifo (
 .wclk (wclk),
 .wrst_n (wrst_n),
 .wptr_binary (wptr_binary),
 .w_en (w_en),
 .rptr_gray_sync(rptr_gray_sync),
 .full (full) );

 // Read-side logic
 read_pointer_fifo #( .addr_size(addr_size) ) u_read_pointer_fifo (
 .rclk (rclk),
 .rrst_n (rrst_n),
 .r_en (r_en),
 .empty (empty),
 .rptr_binary (rptr_binary),
 .rptr_gray (rptr_gray),
 .raddr (raddr) );

 sync_gray_to_rclk_fifo #( .addr_size(addr_size) ) u_sync_gray_to_rclk_fifo (
 .rclk (rclk),
 .rrst_n (rrst_n),
 .wptr_gray (wptr_gray),
 .wptr_gray_sync(wptr_gray_sync) );

 empty_check_fifo #( .addr_size(addr_size) ) u_empty_check_fifo (
 .rptr_gray (rptr_gray),
 .wptr_gray_sync(wptr_gray_sync),
 .empty (empty) );

endmodule

// Byte-in / bit-out asynchronous FIFO: async_fifo_bytein_byteout plus the serializer
// on the read side. Verified by the directed testbench (async_fifo_bytein_bitout_tb.v).
module async_fifo_bytein_bitout
 #( parameter addr_size = 3 )
 (
 input wire wclk,
 input wire wrst_n,
 input wire w_en,
 input wire[7:0] wdata,
 input wire rclk,
 input wire rrst_n,
 input wire r_en,
 output wire full,
 output wire empty,
 output wire serial_out,
 output wire bit_valid );

 // FIFO memory output
 wire[7:0] fifo_rdata;

 // Internal control
 wire fifo_rd_en; // request one byte from FIFO

 async_fifo_bytein_byteout #( .addr_size(addr_size) ) u_async_fifo_bytein_byteout (
 .wclk (wclk),
 .wrst_n (wrst_n),
 .w_en (w_en),
 .wdata (wdata),
 .rclk (rclk),
 .rrst_n (rrst_n),
 .r_en (fifo_rd_en),
 .rdata (fifo_rdata),
 .full (full),
 .empty (empty) );

 // Serializer: converts fetched byte to serial bits
 serializer_bit_out_fifo u_serializer_bit_out_fifo (
 .rclk (rclk),
 .rrst_n (rrst_n),
 .r_en (r_en),
 .empty (empty),
 .fifo_rdata (fifo_rdata),
 .serial_out (serial_out),
 .bit_valid (bit_valid),
 .fifo_rd_en (fifo_rd_en) );

endmodule
 
 // Our read and write operations at each read and write clock happens here
module dual_port_fifo(
    input wire wclk,
    input wire we, // write enable
    input wire [2:0] waddr, // fifo entry count is 8, we need 3 bits to represent address
    input wire [7:0] wdata, // write data is a byte  
    input wire [2:0] raddr, // fifo entry count is 8, we need 3 bits to represent address
    output reg [7:0] rdata // instead of directly output 1 bit, we output a whole byte and use a local shift register to shift out 1 bit at a time (per rclk)
    );

    reg [7:0] fifo [0:7]; // 8 entries in the fifo, each has a width equal to 8 bits
    
    always @(posedge wclk) begin
        if (we) 
            fifo[waddr] <= wdata;
    end
    always @* begin
        rdata = fifo[raddr];
    end
endmodule

module write_pointer_fifo #(
    parameter addr_size = 3
    )(
    input wire wclk,
    input wire wrst_n,
    input wire w_en,
    input wire full,
    output reg[addr_size:0] wptr_binary,
    output reg[addr_size:0] wptr_gray,
    output wire[addr_size-1:0] waddr
    );
    
    reg [addr_size:0] wptr_binary_next;
    reg [addr_size:0] wptr_gray_next;
    
    assign waddr = wptr_binary[addr_size-1:0];
    
    always @* begin
        wptr_binary_next = wptr_binary;
        wptr_gray_next = wptr_gray;
        if (w_en && !full) begin
            wptr_binary_next = wptr_binary + 1'b1;
            wptr_gray_next = (wptr_binary_next >> 1) ^ wptr_binary_next;
        end
    end
    
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wptr_binary <= 4'b0;
            wptr_gray <= 4'b0;
        end
        else begin
            wptr_binary <= wptr_binary_next;
            wptr_gray <= wptr_gray_next;
        end
    end
endmodule

module sync_gray_to_wclk_fifo #(
    parameter addr_size = 3
    )(
    input wire wclk,
    input wire wrst_n,
    input wire[addr_size:0] rptr_gray,
    output reg[addr_size:0] rptr_gray_sync
    );
    
    reg[addr_size:0] sync_ff1;
    
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            sync_ff1 <= 4'b0;
            rptr_gray_sync <= 4'b0;
        end
        else begin
            sync_ff1 <= rptr_gray;
            rptr_gray_sync <= sync_ff1;
        end
    end
endmodule

module full_check_fifo #(
    parameter addr_size = 3
    )(
    input  wire wclk,
    input  wire wrst_n,
    input wire[addr_size:0] wptr_binary,
    input wire w_en,
    input wire[addr_size:0] rptr_gray_sync,
    output reg full
    );
    
    wire[addr_size:0] wptr_binary_next;
    wire[addr_size:0] wptr_gray_next;
    wire full_next;
    
    assign wptr_binary_next = wptr_binary + (w_en ? 1'b1 : 1'b0); // we are trying to predict if the next write pointer will make the FIFO full
    assign wptr_gray_next = (wptr_binary_next >> 1) ^ wptr_binary_next;
    
    assign full_next = (wptr_gray_next == {~rptr_gray_sync[addr_size:addr_size-1], rptr_gray_sync[addr_size-2:0]});
    
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n)
            full <= 1'b0;
        else
            full <= full_next;
    end
endmodule

module read_pointer_fifo #(
    parameter addr_size = 3
    )(
    input wire rclk,
    input wire rrst_n,
    input wire r_en,
    input wire empty,
    output reg[addr_size:0] rptr_binary,
    output reg[addr_size:0] rptr_gray,
    output wire[addr_size-1:0] raddr
    );
    
    reg[addr_size:0] rptr_binary_next;
    reg[addr_size:0] rptr_gray_next;
    
    assign raddr = rptr_binary[addr_size-1:0];
    
    always @* begin
        rptr_binary_next = rptr_binary;
        rptr_gray_next = rptr_gray;
        if (r_en && !empty) begin
            rptr_binary_next = rptr_binary + 1'b1;
            rptr_gray_next = (rptr_binary_next >> 1) ^ rptr_binary_next;
        end
    end
    
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rptr_binary <= 4'b0;
            rptr_gray <= 4'b0;
        end
        else begin
            rptr_binary <= rptr_binary_next;
            rptr_gray <= rptr_gray_next;
        end
    end 
endmodule

module sync_gray_to_rclk_fifo #(
    parameter addr_size = 3
    )(
    input wire rclk,
    input wire rrst_n,
    input wire[addr_size:0] wptr_gray,
    output reg[addr_size:0] wptr_gray_sync
    );
    
    reg[addr_size:0] sync_ff1;
    
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            sync_ff1 <= 4'b0;
            wptr_gray_sync <= 4'b0;
        end
        else begin
            sync_ff1 <= wptr_gray;
            wptr_gray_sync <= sync_ff1;
        end
    end
endmodule

module empty_check_fifo #(
    parameter addr_size = 3
    )(
    input wire [addr_size:0] rptr_gray,
    input wire [addr_size:0] wptr_gray_sync,
    output wire empty
    );
    
    assign empty = (rptr_gray == wptr_gray_sync);
endmodule

module serializer_bit_out_fifo(
    input wire rclk,
    input wire rrst_n,
    input wire r_en, // enable the serial bit output
    input wire empty,
    input wire[7:0] fifo_rdata, // byte read from the fifo
    output reg serial_out, // output bit
    output reg bit_valid,
    output reg fifo_rd_en // byte request signal from the fifo
    );
    
    reg[7:0] shift_register;
    reg[2:0] bit_count;
    
    reg waiting_for_byte; // read request signal sent, waiting for fifo_rdata
    reg shifting; // currently shifting a loaded byte
    
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            shift_register <= 8'b0;
            bit_count <= 3'd0;
            waiting_for_byte <= 1'b0;
            shifting <= 1'b0;
            serial_out <= 1'b0;
            bit_valid <= 1'b0;
            fifo_rd_en <= 1'b0;
        end
        else begin
            fifo_rd_en <= 1'b0;
            bit_valid <= 1'b0;
            
            if (waiting_for_byte) begin // we requested a byte in the previous cycle, we can capture it now
                shift_register <= fifo_rdata;
                bit_count <= 3'd7;
                waiting_for_byte <= 1'b0;
                shifting <= 1'b1;
            end
            else if (shifting) begin
                if (r_en) begin
                    serial_out <= shift_register[7];
                    bit_valid <= 1'b1;
                    shift_register <= {shift_register[6:0], 1'b0};
                    bit_count <= bit_count - 1'b1;
                    
                    if (bit_count == 3'd0) begin
                        shifting <= 1'b0;
                        if (!empty) begin
                            fifo_rd_en <= 1'b1;
                            waiting_for_byte <= 1'b1;
                        end
                    end
                end
            end
            else begin
                if (r_en && !empty) begin
                    fifo_rd_en <= 1'b1;
                    waiting_for_byte <= 1'b1;
                end
            end
        end    
    end    
endmodule
