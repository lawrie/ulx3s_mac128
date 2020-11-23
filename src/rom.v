module rom (
  input             clk,
  input [16:1]      addr,
  output reg [15:0] dout,
);

  parameter MEM_INIT_FILE = "";
   
  reg [15:0] rom [0:65535];

  initial
    if (MEM_INIT_FILE != "")
      $readmemh(MEM_INIT_FILE, rom);
   
  always @(posedge clk) begin
    dout <= rom[addr];
  end

endmodule
