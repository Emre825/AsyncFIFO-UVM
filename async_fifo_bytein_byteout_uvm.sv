`timescale 1ns/1ps

// UVM testbench for async_fifo_bytein_byteout (async_fifo.v), the byte-in/byte-out
// asynchronous FIFO that async_fifo_bytein_bitout is built on (everything except
// the serializer). Targets Vivado XSim.
//
// DUT signals, as named in the testbench
//   write side: wclk, wrst, wen, wdata, wfull
//   read side:  rclk, rrst, ren, rdata, rempty
//   BW=8 bits, DEPTH=8 entries (AW=3). Resets are active-high in the testbench
//   and inverted at the DUT, which takes active-low resets.
//
// Clocks
//   - wclk: fixed 24 ns half-period (48 ns period).
//   - rclk: variable half-period (package variable `rhperiod`), swept by the
//           read side across {144, 5, 30, 14, 171} ns so the FIFO is exercised
//           with rclk slower than, faster than, and close to wclk.
//
// Structure
//   async_fifo_if                  - DUT signals
//   write_agent                    - sequencer + write_driver (reset, write bursts)
//   read_agent                     - sequencer + read_driver (reset, read bursts)
//                                    + read_monitor (checks rdata on every read)
//   fifo_scoreboard                - reference queue, push/pop counters, verify()
//   phase_sync                     - lockstep handshake between the two sides
//   write_main_seq / read_main_seq - one round of stimulus
//   write_top_seq / read_top_seq   - 5 rounds; the read side picks a new rclk
//                                    period for each round
//
// Lockstep handshake (so the write and read sides do not race)
//   phase_sync holds the counters wphase and rphase.
//     wsync(): wphase++; wait on wclk until rphase >= wphase; one more wclk.
//     rsync(): symmetric on rclk.
//   Both main sequences place a sync between stimulus steps, so the writer
//   and reader proceed step by step through matched phases.
//
// One round of stimulus (write side / read side, paired by sync points)
//   1. Reset own domain (5 cycles of each clock).
//      Check wfull == 0 / rempty == 1.
//   2. Single write of 0x10 / single read.
//   3. DEPTH single writes of 0x11 (fills the FIFO, wfull must assert) /
//      one read, wait for !wfull, then DEPTH-1 reads (rempty must assert).
//   4. Burst of DEPTH writes from 0x19 / burst of DEPTH reads.
//   5. Burst of 10*DEPTH writes from 0x21 / burst of 10*DEPTH reads
//      (long back-pressured bursts running concurrently).
//
// Driving and checking
//   - write_driver waits while wfull, read_driver waits while rempty. Flags
//     are sampled #2 after the clock edge and pins are driven with `<= #1`,
//     so the DUT never sees an input change on a clock edge.
//   - Every write stores the byte in the scoreboard queue; read_monitor
//     compares rdata with the queue entry at the read pointer on every rclk
//     edge where ren is high. A mismatch is reported as a UVM_ERROR
//     (id FIFO_CHECK), not a fatal.
//   - The wfull / rempty checks listed above are made by the main sequences.
//
// End of test
//   The test ends when both top sequences finish; it then checks that both
//   sides went through all 35 sync phases (5 rounds x 7) and prints the final
//   push/pop counts. A watchdog in the top module stops the simulation after
//   10000 wclk cycles in case a sequence hangs.

`include "uvm_macros.svh"

interface async_fifo_if;
    logic wclk;
    logic wrst;
    logic wen;
    logic [7:0] wdata;
    logic rclk;
    logic rrst;
    logic ren;
    logic [7:0] rdata;
    logic wfull;
    logic rempty;
endinterface

package async_fifo_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam int BW = 8;
    localparam int DEPTH = 8;
    localparam int AW = 3;   // $clog2(DEPTH)

    real rhperiod = 144.0;

    // phase_sync  -  lockstep handshake between the write and read sides
    class phase_sync extends uvm_object;
        `uvm_object_utils(phase_sync)
        int wphase = 0;
        int rphase = 0;

        function new(string name = "phase_sync");
            super.new(name);
        endfunction

        // task wsync:  wphase++; wait on wclk until rphase >= wphase;
        //              one more wclk edge.
        task wsync(virtual async_fifo_if vif);
            wphase++;
            forever begin
                @(posedge vif.wclk);
                if (rphase >= wphase) break;
            end
            @(posedge vif.wclk);
        endtask

        // task rsync:  rphase++; wait on rclk until wphase >= rphase;
        //              one more rclk edge.
        task rsync(virtual async_fifo_if vif);
            rphase++;
            forever begin
                @(posedge vif.rclk);
                if (wphase >= rphase) break;
            end
            @(posedge vif.rclk);
        endtask
    endclass

    // fifo_scoreboard  -  reference queue with its write/read pointers,
    //                     push/pop counters and the verify() check
    class fifo_scoreboard extends uvm_component;
        `uvm_component_utils(fifo_scoreboard)
        bit [BW-1:0] queue [0:(16*DEPTH-1)];
        bit [AW+3:0] wptr;  // 7-bit, wraps mod 128 (the queue size)
        bit [AW+3:0] rptr;  // 7-bit, wraps mod 128 (the queue size)
        int pushes = 0;
        int pops = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void verify(bit cond, string msg, bit [BW-1:0] obs = '0, bit [BW-1:0] exp_ = '0);
            if (!cond) begin
                `uvm_error("FIFO_CHECK",
                    $sformatf("%s (%h vs queue=%h)", msg, obs, exp_))
            end
        endfunction
    endclass

    // Transactions
    typedef enum {W_RESET, W_BURST, W_SYNC} write_cmd_e;

    class write_command extends uvm_sequence_item;
        `uvm_object_utils(write_command)
        write_cmd_e cmd;
        int num_cycles;
        int burst_length;
        bit [BW-1:0] start_data;

        function new(string name = "write_command");
            super.new(name);
        endfunction
    endclass

    typedef enum {R_RESET, R_BURST, R_SYNC, R_WAIT_NOT_FULL} read_cmd_e;

    class read_command extends uvm_sequence_item;
        `uvm_object_utils(read_command)
        read_cmd_e cmd;
        int num_cycles;
        int burst_length;

        function new(string name = "read_command");
            super.new(name);
        endfunction
    endclass

    // Sequencer typedefs
    typedef uvm_sequencer#(write_command) write_sequencer;
    typedef uvm_sequencer#(read_command) read_sequencer;

    // write_driver  -  write-domain reset and write bursts
    class write_driver extends uvm_driver#(write_command);
        `uvm_component_utils(write_driver)
        virtual async_fifo_if vif;
        fifo_scoreboard sb;
        phase_sync sync;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual async_fifo_if)::get(this, "", "vif", vif))
                `uvm_fatal("NO_VIF", "write_driver: vif not in config_db")
            if (!uvm_config_db#(fifo_scoreboard)::get(this, "", "sb", sb))
                `uvm_fatal("NO_SB",  "write_driver: scoreboard not in config_db")
            if (!uvm_config_db#(phase_sync)::get(this, "", "sync", sync))
                `uvm_fatal("NO_SYNC","write_driver: phase_sync not in config_db")
        endfunction

        task run_phase(uvm_phase phase);
            write_command cmd;
            forever begin
                seq_item_port.get_next_item(cmd);
                case (cmd.cmd)
                    W_RESET: do_wrst(cmd.num_cycles);
                    W_BURST: fifo_write(cmd.burst_length, cmd.start_data);
                    W_SYNC: sync.wsync(vif);
                endcase
                seq_item_port.item_done();
            end
        endtask

        // Write-domain reset: wrst is held for num_cycles edges of each clock,
        // so both domains see it, then released, followed by one more wclk edge.
        task do_wrst(int num_cycles);
            vif.wrst = 0;
            @(posedge vif.rclk);
            @(posedge vif.wclk);
            vif.wrst <= #1 1;
            repeat (num_cycles) @(posedge vif.rclk);
            repeat (num_cycles) @(posedge vif.wclk);
            vif.wrst <= #1 0;
            @(posedge vif.wclk);
        endtask

        // Writes burst_length bytes counting up from start_data, waiting
        // while wfull. Timing-critical: wfull is sampled #2 after the clock
        // edge and the pins are driven with `<= #1`.
        task fifo_write(int burst_length, bit [BW-1:0] start_data);
            bit [BW-1:0] data;
            data = start_data;
            repeat (burst_length) begin
                forever begin
                    #2;
                    if (!vif.wfull) break;
                    vif.wen <= #1 0;
                    @(posedge vif.wclk);
                end
                #2;
                vif.wen        <= #1 1;
                vif.wdata      <= #1 data;
                sb.pushes++;
                sb.queue[sb.wptr] <= #1 data;
                data            = data + 1;
                @(posedge vif.wclk);
                sb.wptr        <= #1 sb.wptr + 1;
            end
            vif.wen <= #1 0;
            @(posedge vif.wclk);
        endtask
    endclass

    // read_driver  -  read-domain reset and read bursts
    class read_driver extends uvm_driver#(read_command);
        `uvm_component_utils(read_driver)
        virtual async_fifo_if vif;
        fifo_scoreboard sb;
        phase_sync sync;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual async_fifo_if)::get(this, "", "vif", vif))
                `uvm_fatal("NO_VIF", "read_driver: vif not in config_db")
            if (!uvm_config_db#(fifo_scoreboard)::get(this, "", "sb", sb))
                `uvm_fatal("NO_SB",  "read_driver: scoreboard not in config_db")
            if (!uvm_config_db#(phase_sync)::get(this, "", "sync", sync))
                `uvm_fatal("NO_SYNC","read_driver: phase_sync not in config_db")
        endfunction

        task run_phase(uvm_phase phase);
            read_command cmd;
            forever begin
                seq_item_port.get_next_item(cmd);
                case (cmd.cmd)
                    R_RESET: do_rrst(cmd.num_cycles);
                    R_BURST: fifo_read(cmd.burst_length);
                    R_SYNC: sync.rsync(vif);
                    R_WAIT_NOT_FULL: wait_not_full();
                endcase
                seq_item_port.item_done();
            end
        endtask

        // Read-domain reset: same scheme as write_driver::do_wrst.
        task do_rrst(int num_cycles);
            vif.rrst = 0;
            @(posedge vif.wclk);
            @(posedge vif.rclk);
            vif.rrst <= #1 1;
            repeat (num_cycles) @(posedge vif.wclk);
            repeat (num_cycles) @(posedge vif.rclk);
            vif.rrst <= #1 0;
            @(posedge vif.rclk);
        endtask

        // Reads burst_length bytes, waiting while rempty. Timing-critical:
        // same sampling and driving scheme as write_driver::fifo_write.
        task fifo_read(int burst_length);
            repeat (burst_length) begin
                forever begin
                    #2;
                    if (!vif.rempty) break;
                    vif.ren <= #1 0;
                    @(posedge vif.rclk);
                end
                vif.ren <= #1 1;
                sb.pops++;
                @(posedge vif.rclk);
                sb.rptr <= #1 sb.rptr + 1;
            end
            vif.ren <= #1 0;
            @(posedge vif.rclk);
        endtask

        // Waits until !wfull on rclk edges, then one more edge.
        task wait_not_full();
            forever begin
                @(posedge vif.rclk);
                if (!vif.wfull) break;
            end
            @(posedge vif.rclk);
        endtask
    endclass

    // read_monitor  -  on every rclk edge with ren high, checks rdata against
    //                  the scoreboard queue
    class read_monitor extends uvm_monitor;
        `uvm_component_utils(read_monitor)
        virtual async_fifo_if vif;
        fifo_scoreboard sb;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual async_fifo_if)::get(this, "", "vif", vif))
                `uvm_fatal("NO_VIF", "read_monitor: vif not in config_db")
            if (!uvm_config_db#(fifo_scoreboard)::get(this, "", "sb", sb))
                `uvm_fatal("NO_SB",  "read_monitor: scoreboard not in config_db")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.rclk);
                if (vif.ren) begin
                    sb.verify(sb.queue[sb.rptr] === vif.rdata,
                              "FIFO rdata mismatch",
                              vif.rdata, sb.queue[sb.rptr]);
                end
            end
        endtask
    endclass

    // Agents
    class write_agent extends uvm_agent;
        `uvm_component_utils(write_agent)
        write_sequencer seqr;
        write_driver    drv;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            seqr = write_sequencer::type_id::create("seqr", this);
            drv  = write_driver   ::type_id::create("drv",  this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(seqr.seq_item_export);
        endfunction
    endclass

    class read_agent extends uvm_agent;
        `uvm_component_utils(read_agent)
        read_sequencer seqr;
        read_driver    drv;
        read_monitor   mon;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            seqr = read_sequencer::type_id::create("seqr", this);
            drv  = read_driver   ::type_id::create("drv",  this);
            mon  = read_monitor  ::type_id::create("mon",  this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(seqr.seq_item_export);
        endfunction
    endclass

    // Environment
    class async_fifo_env extends uvm_env;
        `uvm_component_utils(async_fifo_env)
        fifo_scoreboard sb;
        phase_sync sync;
        write_agent wagent;
        read_agent ragent;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sb   = fifo_scoreboard::type_id::create("sb",   this);
            sync = phase_sync::type_id::create("sync");

            uvm_config_db#(fifo_scoreboard)::set(this, "*", "sb",   sb);
            uvm_config_db#(phase_sync)     ::set(this, "*", "sync", sync);

            wagent = write_agent::type_id::create("wagent", this);
            ragent = read_agent ::type_id::create("ragent", this);
        endfunction
    endclass

    // Sequences
    // write_main_seq  -  one round of write-side stimulus
    class write_main_seq extends uvm_sequence#(write_command);
        `uvm_object_utils(write_main_seq)
        fifo_scoreboard sb;
        virtual async_fifo_if vif;

        function new(string name = "write_main_seq");
            super.new(name);
        endfunction

        task issue(write_cmd_e c, int n = 0, int len = 0, bit [7:0] d = '0);
            write_command t;
            t = write_command::type_id::create("t");
            start_item(t);
            t.cmd = c;
            t.num_cycles = n;
            t.burst_length = len;
            t.start_data = d;
            finish_item(t);
        endtask

        task body();
            // Start of a round: idle the write enable and rewind the
            // scoreboard write pointer.
            vif.wen = 0;
            sb.wptr = 0;

            // 1. Reset; the FIFO must not be full.
            issue(W_RESET, .n(5));
            sb.verify(vif.wfull === 1'b0, "wfull !== 0");
            issue(W_SYNC);

            // 2. Single write.
            issue(W_BURST, .len(1), .d(8'h10));
            issue(W_SYNC);

            // 3. DEPTH single writes, each of 8'h11, fill the FIFO; it must
            //    now be full.
            repeat (DEPTH) issue(W_BURST, .len(1), .d(8'h11));
            sb.verify(vif.wfull !== 1'b0, "wfull === 0");
            issue(W_SYNC);
            issue(W_SYNC);

            // 4. One burst of DEPTH writes; the FIFO must be full again.
            issue(W_BURST, .len(DEPTH), .d(8'h19));
            sb.verify(vif.wfull !== 1'b0, "wfull === 0");
            issue(W_SYNC);
            issue(W_SYNC);

            // 5. Long burst, back-pressured by the read side, then 100 idle
            //    wclk cycles.
            issue(W_BURST, .len(10*DEPTH), .d(8'h21));
            repeat (100) @(posedge vif.wclk);
            issue(W_SYNC);
        endtask
    endclass

    // read_main_seq  -  one round of read-side stimulus
    class read_main_seq extends uvm_sequence#(read_command);
        `uvm_object_utils(read_main_seq)
        fifo_scoreboard sb;
        virtual async_fifo_if vif;

        function new(string name = "read_main_seq");
            super.new(name);
        endfunction

        task issue(read_cmd_e c, int n = 0, int len = 0);
            read_command t;
            t = read_command::type_id::create("t");
            start_item(t);
            t.cmd = c;
            t.num_cycles = n;
            t.burst_length = len;
            finish_item(t);
        endtask

        task body();
            // Start of a round: idle the read enable and rewind the
            // scoreboard read pointer.
            vif.ren = 0;
            sb.rptr = 0;

            // 1. Reset; the FIFO must be empty.
            issue(R_RESET, .n(5));
            sb.verify(vif.rempty === 1'b1, "rempty !== 1");
            issue(R_SYNC);

            // 2. Single read.
            issue(R_BURST, .len(1));
            issue(R_SYNC);
            issue(R_SYNC);

            // 3. The FIFO is full: read one byte, wait for wfull to drop,
            //    then read the remaining DEPTH-1 bytes. It must now be empty.
            issue(R_BURST, .len(1));
            issue(R_WAIT_NOT_FULL);

            repeat (DEPTH-1) issue(R_BURST, .len(1));
            sb.verify(vif.rempty === 1'b1, "rempty !== 1");
            issue(R_SYNC);
            issue(R_SYNC);

            // 4. One burst of DEPTH reads; the FIFO must be empty again.
            issue(R_BURST, .len(DEPTH));
            sb.verify(vif.rempty === 1'b1, "rempty !== 1");
            issue(R_SYNC);

            // 5. Long burst, concurrent with the write side's long burst; the
            //    FIFO must end up empty.
            issue(R_BURST, .len(10*DEPTH));
            sb.verify(vif.rempty === 1'b1, "rempty !== 1");
            issue(R_SYNC);
        endtask
    endclass

    // write_top_seq  -  5 rounds of write_main_seq
    class write_top_seq extends uvm_sequence#(write_command);
        `uvm_object_utils(write_top_seq)
        fifo_scoreboard sb;
        virtual async_fifo_if vif;

        function new(string name = "write_top_seq");
            super.new(name);
        endfunction

        task body();
            write_main_seq m;
            repeat (5) begin
                m = write_main_seq::type_id::create("m");
                m.sb  = sb;
                m.vif = vif;
                m.start(m_sequencer, this);
            end
        endtask
    endclass

    // read_top_seq  -  5 rounds of read_main_seq, each at a different rclk
    //                  period; prints the push/pop counts after each round
    class read_top_seq extends uvm_sequence#(read_command);
        `uvm_object_utils(read_top_seq)
        fifo_scoreboard sb;
        virtual async_fifo_if vif;

        function new(string name = "read_top_seq");
            super.new(name);
        endfunction

        task one(real period);
            read_main_seq m;
            rhperiod = period;             // updates top-module clock gen
            m = read_main_seq::type_id::create("m");
            m.sb  = sb;
            m.vif = vif;
            m.start(m_sequencer, this);
            $display("pushes=%0d, pops=%0d", sb.pushes, sb.pops);
        endtask

        task body();
            // rclk half-periods in ns; the wclk half-period is 24
            one(144.0);
            one(  5.0);
            one( 30.0);
            one( 14.0);
            one(171.0);
        endtask
    endclass

    // Test
    class async_fifo_test extends uvm_test;
        `uvm_component_utils(async_fifo_test)
        async_fifo_env        env;
        virtual async_fifo_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual async_fifo_if)::get(this, "", "vif", vif))
                `uvm_fatal("NO_VIF", "test: vif not in config_db")
            uvm_config_db#(virtual async_fifo_if)::set(this, "*", "vif", vif);
            env = async_fifo_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            write_top_seq wts;
            read_top_seq  rts;
            phase.raise_objection(this);

            wts = write_top_seq::type_id::create("wts");
            rts = read_top_seq ::type_id::create("rts");
            wts.sb  = env.sb;  wts.vif = vif;
            rts.sb  = env.sb;  rts.vif = vif;

            fork
                wts.start(env.wagent.seqr);
                rts.start(env.ragent.seqr);
            join

            // Both sides must have gone through all 35 sync phases
            // (5 rounds x 7).
            env.sb.verify(env.sync.wphase >= 35, "wphase < 35");
            env.sb.verify(env.sync.rphase >= 35, "rphase < 35");
            $display("pushes=%0d, pops=%0d", env.sb.pushes, env.sb.pops);

            phase.drop_objection(this);
        endtask
    endclass

endpackage : async_fifo_pkg


// Top module
module async_fifo_bytein_byteout_uvm;
    import uvm_pkg::*;
    import async_fifo_pkg::*;

    localparam BW    = 8;
    localparam DEPTH = 8;
    localparam AW    = $clog2(DEPTH);

    async_fifo_if vif();

    // Local nets for DUT instantiation
    wire wclk = vif.wclk;
    wire wrst = vif.wrst;
    wire wen = vif.wen;
    wire [BW-1:0] wdata = vif.wdata;
    wire rclk = vif.rclk;
    wire rrst = vif.rrst;
    wire ren = vif.ren;
    wire [BW-1:0] rdata;
    wire wfull;
    wire rempty;

    assign vif.rdata = rdata;
    assign vif.wfull = wfull;
    assign vif.rempty = rempty;

    // DUT. The testbench drives active-high resets; the FIFO takes
    // active-low resets, so both are inverted here.
    async_fifo_bytein_byteout #(.addr_size(AW)) dut (
        .wclk   (wclk),
        .wrst_n (~wrst),
        .w_en   (wen),
        .wdata  (wdata),
        .rclk   (rclk),
        .rrst_n (~rrst),
        .r_en   (ren),
        .rdata  (rdata),
        .full   (wfull),
        .empty  (rempty)
    );

    // Initialize TB-driven inputs to 0 at time 0 so the DUT does not see
    // X on wrst/rrst/wen/ren/wdata before the UVM run_phase begins.
    initial begin
        vif.wrst = 0;
        vif.rrst = 0;
        vif.wen = 0;
        vif.ren = 0;
        vif.wdata = '0;
    end

    // Clock generators
    initial begin
        vif.wclk = 0;
        forever #24 vif.wclk = ~vif.wclk;
    end

    initial begin
        vif.rclk = 0;
        // rhperiod is async_fifo_pkg::rhperiod; read_top_seq mutates it.
        forever #rhperiod vif.rclk = ~vif.rclk;
    end

    // VCD dump
    initial begin
        $dumpfile("async_fifo_bytein_byteout_uvm.vcd");
        $dumpvars(0, async_fifo_bytein_byteout_uvm);
    end

    // Bring up UVM
    initial begin
        uvm_config_db#(virtual async_fifo_if)::set(null, "uvm_test_top",
                                                    "vif", vif);
        run_test("async_fifo_test");
    end

    // Watchdog - hard-stops the simulation after 10000 wclk cycles in case
    // the sequences hang. The end-of-test checks are in
    // async_fifo_test::run_phase.
    initial begin
        repeat (10000) @(posedge vif.wclk);
        $display("Watchdog: 10000 wclk cycles elapsed, ending simulation");
        $finish;
    end

endmodule
