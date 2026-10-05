`timescale 1ns/1ps
module c64_joystick_tb;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst = 1;
  reg [5:0] joya = 6'h3f, joyb = 6'h3f;
  reg [9:0] companion_a = 0, companion_b = 0;
  c64_top dut (
    .clk(clk), .rst(rst), .joya(joya), .joyb(joyb),
    .companion_joy_a(companion_a), .companion_joy_b(companion_b)
  );
  integer bit_index;
  initial begin
    // Other C64 cores are omitted; drive the USB outputs explicitly.
    force dut.usb_joy_a = 10'h200;
    force dut.usb_joy_b = 10'h100;
    repeat (2) @(negedge clk);
    if (dut.joy_a !== 10'h200 || dut.joy_b !== 10'h100)
      $fatal(1, "reset generated active GPIO contacts");
    rst = 0;
    for (bit_index = 0; bit_index < 10; bit_index = bit_index + 1) begin
      companion_a = 10'b1 << bit_index;
      companion_b = 10'b1 << (9-bit_index);
      #1;
      if (dut.joy_a !== (10'h200 | companion_a) ||
          dut.joy_b !== (10'h100 | companion_b))
        $fatal(1, "companion bit mapping or cross-port leakage");
    end
    companion_a = 10'h080;
    companion_b = 10'h040;
    for (bit_index = 0; bit_index < 6; bit_index = bit_index + 1) begin
      joya = ~(6'b1 << bit_index);
      joyb = ~(6'b1 << (5-bit_index));
      @(negedge clk);
      if (dut.joy_a !== 10'h280 || dut.joy_b !== 10'h140)
        $fatal(1, "GPIO synchronization missing second stage");
      @(negedge clk);
      if (dut.joy_a !== (10'h280 | (10'b1 << bit_index)) ||
          dut.joy_b !== (10'h140 | (10'b1 << (5-bit_index))))
        $fatal(1, "GPIO/USB/companion sources did not combine");
      joya = 6'h3f;
      joyb = 6'h3f;
      repeat (2) @(negedge clk);
    end
    // Releasing one source must not release a button held by another.
    force dut.usb_joy_a = 10'h010;
    force dut.usb_joy_b = 10'h020;
    companion_a = 10'h010;
    companion_b = 10'h020;
    joya = 6'h2f;
    joyb = 6'h1f;
    repeat (2) @(negedge clk);
    companion_a = 0;
    companion_b = 0;
    #1;
    if (dut.joy_a !== 10'h010 || dut.joy_b !== 10'h020)
      $fatal(1, "companion release cleared another source");
    force dut.usb_joy_a = 0;
    force dut.usb_joy_b = 0;
    #1;
    if (dut.joy_a !== 10'h010 || dut.joy_b !== 10'h020)
      $fatal(1, "USB release cleared GPIO contacts");
    joya = 6'h3f;
    joyb = 6'h3f;
    repeat (2) @(negedge clk);
    if (dut.joy_a !== 0 || dut.joy_b !== 0)
      $fatal(1, "neutral sources left buttons stuck");
    $display("PASS: both joystick ports combine GPIO, USB and companion states");
    $finish;
  end
endmodule
