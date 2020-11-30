`default_nettype none
module video (
  input             clk,
  input             reset,
  output [7:0]      vga_r,
  output [7:0]      vga_b,
  output [7:0]      vga_g,
  output            vga_hs,
  output            vga_vs,
  output            vga_de,
  input  [15:0]     vid_dout,
  output [14:1]     vid_addr
);

  parameter HA = 640;
  parameter HS  = 96;
  parameter HFP = 16;
  parameter HBP = 48;
  parameter HT  = HA + HS + HFP + HBP;
  parameter HB = 64;
  parameter HBadj = 0;

  parameter VA = 480;
  parameter VS  = 2;
  parameter VFP = 11;
  parameter VBP = 31;
  parameter VT  = VA + VS + VFP + VBP;
  parameter VB = 69;

  reg [9:0] hc = 0;
  reg [9:0] vc = 0;

  always @(posedge clk) begin
    if (reset) begin
      hc <= 0;
      vc <= 0;
    end else begin
      if (hc == HT - 1) begin
        hc <= 0;
        if (vc == VT - 1) vc <= 0;
        else vc <= vc + 1;
      end else hc <= hc + 1;
    end
  end

  assign vga_hs = !(hc >= HA + HFP && hc < HA + HFP + HS);
  assign vga_vs = !(vc >= VA + VFP && vc < VA + VFP + VS);
  assign vga_de = !(hc >= HA || vc >= VA);

  wire [8:0] x = hc - HB;
  wire [8:0] y = vc - VB;
  wire [8:0] x16 = x + 16;

  assign vid_addr = {y, x16[8:4]};

  wire hBorder = (hc < (HB + HBadj) || hc >= HA - (HB + HBadj));
  wire vBorder = (vc < VB || vc >= VA - VB);
  wire border = hBorder || vBorder;

  reg [15:0] pixel_data;
  always @(posedge clk) begin
    if (hc[3:0] == 15) pixel_data <= vid_dout;
    else pixel_data <= {pixel_data[14:0], 1'b0};
  end
  
  wire pixel = pixel_data[15];
  wire [7:0] green = border ? 8'b0 : {8{pixel}};
  wire [7:0] red   = border ? 8'b0 : {8{pixel}};
  wire [7:0] blue  = border ? 8'b0 : {8{pixel}};

  assign vga_r = !vga_de ? 8'b0 : red;
  assign vga_g = !vga_de ? 8'b0 : green;
  assign vga_b = !vga_de ? 8'b0 : blue;

endmodule

