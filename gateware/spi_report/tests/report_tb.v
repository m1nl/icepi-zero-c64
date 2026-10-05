`timescale 1ns/1ps
module tb #(parameter DEBUG = 0);
    reg sys_clk = 0;
    always #5 sys_clk = ~sys_clk;
    reg sys_rst = 0;
    reg spi_cs_n = 1, spi_clk = 0, spi_mosi = 0;
    reg [29:0] bus_adr = 0;
    reg [3:0] bus_sel = 0;
    reg bus_cyc = 0, bus_stb = 0, bus_we = 0;
    wire [31:0] bus_dat_r;
    wire bus_ack, irq;
    wire [1:0] status;
    spi_report_top dut (.*);
    integer i;
    reg [31:0] value;

    task start_packet;
        begin spi_cs_n = 0; #31; end
    endtask
    task end_packet;
        begin spi_cs_n = 1; #51; end
    endtask
    task send_bit(input bit data);
        // SCK is faster than sys_clk: verifies reception is SCK-clocked.
        begin spi_clk = 1; spi_mosi = data; #3; spi_clk = 0; #3; end
    endtask
    task send_byte(input [7:0] data);
        integer b;
        begin for (b = 7; b >= 0; b = b - 1) send_bit(data[b]); end
    endtask
    task access(input [1:0] word_addr, input [3:0] lanes, input bit write_access);
        begin
            @(negedge sys_clk);
            bus_adr = word_addr; bus_sel = lanes; bus_we = write_access;
            bus_cyc = 1; bus_stb = 1;
            @(negedge sys_clk);
            if (!bus_ack) $fatal(1, "missing Wishbone ack");
            value = bus_dat_r;
            @(negedge sys_clk);
            bus_cyc = 0; bus_stb = 0; bus_we = 0;
            @(negedge sys_clk);
            if (bus_ack) $fatal(1, "ack held after transfer");
        end
    endtask
    task read_byte(input [1:0] address, input [3:0] lanes, input [31:0] expected);
        begin
            access(address, lanes, 0);
            if (value !== expected)
                $fatal(1, "FIFO data: got=%h expected=%h", value, expected);
        end
    endtask
    task clear_buffer;
        begin while (status[0]) access(0, 15, 0); end
    endtask
    task reset_buffer;
        begin
            sys_rst = 1; #31; sys_rst = 0; #31;
            if (status !== 0 || irq !== 0) $fatal(1, "reset status");
        end
    endtask

    initial begin
        #1; sys_rst = 1; #30; sys_rst = 0; #31;
        if (status !== 0 || irq !== 0) $fatal(1, "initial status");
        start_packet(); send_byte(8'h02); send_byte(8'h01); end_packet();
        if (status !== 0 || irq !== 0) $fatal(1, "other target accepted");
        start_packet(); send_byte(8'h01);
        for (i = 1; i < 8; i = i + 1) send_byte(i);
        end_packet();
        if (status !== 1 || irq !== 1) $fatal(1, "full buffer appears empty");
        access(2, 15, 0);
        if (value !== (DEBUG ? 32'd8 : 32'd0) || !irq) $fatal(1, "producer count/metadata ack");
        access(3, 15, 0);
        if (value !== 32'h11 || !irq) $fatal(1, "head level/start marker");
        access(0, 0, 0);
        if (!irq) $fatal(1, "zero sel consumed data");
        access(0, 15, 1);
        if (!irq) $fatal(1, "write consumed data");
        // Word reads return one zero-extended byte. Byte loads at successive
        // addresses return the next byte in the lane the CPU requested.
        read_byte(0, 15, 32'h01);
        read_byte(0, 2, 32'h00000100);
        read_byte(0, 4, 32'h00020000);
        read_byte(0, 8, 32'h03000000);
        read_byte(1, 1, 32'h04);
        read_byte(1, 2, 32'h00000500);
        read_byte(1, 4, 32'h00060000);
        read_byte(1, 8, 32'h07000000);
        if (irq !== 0 || status !== 0) $fatal(1, "drain did not clear IRQ");
        // Empty reads do not advance the pointer or manufacture bytes.
        read_byte(0, 15, 0);
        read_byte(1, 15, 0);

        // Circular overwrite retains the most recent eight bytes, in order.
        start_packet(); send_byte(8'h01);
        for (i = 1; i < 10; i = i + 1) send_byte(8'h80 + i);
        end_packet();
        access(2, 15, 0);
        if (value !== (DEBUG ? 32'd18 : 32'd0)) $fatal(1, "producer count after wrap");
        access(3, 15, 0);
        if (value !== (DEBUG ? 32'h50 : 32'h10)) $fatal(1, "overrun count/level/start marker");
        for (i = 2; i < 10; i = i + 1)
            read_byte(0, 15, 32'h80 + i);
        if (irq !== 0 || status !== 0) $fatal(1, "wrap drain");

        // A simultaneous read and full write returns the OLD head exactly
        // once, keeps eight entries, and does not report an overrun.
        reset_buffer();
        start_packet(); send_byte(8'h01);
        for (i = 1; i < 8; i = i + 1) send_byte(i);
        #31;
        fork
            send_byte(8'haa);
            begin
                wait (dut.spi_report_slave.wr_en === 1'b1);
                read_byte(0, 15, 1);
            end
        join
        end_packet();
        access(3, 15, 0);
        if (value !== 32'h10) $fatal(1, "simultaneous full read/write metadata");
        for (i = 1; i < 8; i = i + 1)
            read_byte(0, 15, i);
        read_byte(0, 15, 32'haa);
        if (irq !== 0) $fatal(1, "simultaneous full read/write drain");

        reset_buffer();
        start_packet();
        send_bit(0); send_bit(0); send_bit(0);
        if (!status[1]) $fatal(1, "missing receiving during partial byte");
        end_packet();
        if (irq !== 0 || status !== 0) $fatal(1, "partial target recorded");
        start_packet(); send_byte(8'h01); send_byte(8'hab);
        // End CS immediately after the last completed byte.
        end_packet();
        if (!irq || status[1]) $fatal(1, "final byte CDC lost/still receiving");
        read_byte(0, 15, 1);
        read_byte(0, 15, 32'hab);
        if (irq !== 0) $fatal(1, "report not intact");
        // A target-only packet is retained; CS resets packet decoding.
        start_packet(); send_byte(8'h01); end_packet();
        if (!irq) $fatal(1, "target-only packet lost");
        clear_buffer();
        start_packet(); send_byte(8'h03); send_byte(8'hff); end_packet();
        if (irq) $fatal(1, "target selection persisted across CS");
        $display("PASS: SCK reception, target filtering, CDC, circular RAM, Wishbone, CSR, IRQ");
        $finish;
    end
    initial begin #100000; $fatal(1, "timeout"); end
endmodule
