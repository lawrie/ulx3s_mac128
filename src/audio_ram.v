module audio_ram (
  input             clk,
  input [8:0]       raddr,
  input [8:0]       waddr,
  input [7:0]       din,
  input             we,
  output reg [7:0]  dout,
);

  parameter c_sound_len = 370;

  reg [7:0] ram [0:c_sound_len - 1];

  always @(posedge clk) begin
    dout <= ram[raddr];
    if (we) ram[waddr] <= din;
  end

endmodule

