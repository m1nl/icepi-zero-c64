module muladd (
  input  logic signed [31:0] c,
  input  logic               s,  // 0 = add, 1 = subtract
  input  logic signed [15:0] a,
  input  logic signed [15:0] b,
  output logic signed [31:0] o
);

logic signed [31:0] m;

// 16x16 signed multiply
assign m = a * b;

// Add / subtract
assign o = s ? (c - m) : (c + m);

endmodule
