module ram8 (
  input             clk,
  input [13:0]      addr,
  input [7:0]       din,
  input             we,
  output reg [7:0] dout,
);

  parameter MEM_INIT_FILE = "";
   
  reg [7:0] rom [0:12287];

  initial
    if (MEM_INIT_FILE != "")
      $readmemh(MEM_INIT_FILE, rom);
   
  always @(posedge clk) begin
    dout <= rom[addr];
    if (we) rom[addr] <= din;
  end

endmodule
