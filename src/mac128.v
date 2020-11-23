`default_nettype none
module mac128
#(
  parameter c_slowdown    = 0, // CPU clock slowdown 2^n times (try 20-22)
  parameter c_lcd_hex     = 1, // SPI LCD HEX decoder
  parameter c_vga_out     = 0, // 0: Just HDMI, 1: VGA and HDMI
  parameter c_diag        = 1, // 0: No LED diagnostcs, 1: LED diagnostics
  parameter c_mhz         = 27000000, // Clock speed of CPU clock
  parameter c_screen_base = 24'h3fa700,
  parameter c_screen_top = c_screen_base + 24'h5800
)
(
  input         clk_25mhz,
  // Buttons
  input   [6:0] btn,
  // Switches
  input   [3:0] sw,
  // HDMI
  output  [3:0] gpdi_dp,
  // Keyboard
  output        usb_fpga_pu_dp,
  output        usb_fpga_pu_dn,
  inout         ps2Clk,
  inout         ps2Data,
  // Audio
  output  [3:0] audio_l,
  output  [3:0] audio_r,
  // ESP32 passthru
  input         ftdi_txd,
  output        ftdi_rxd,
  input         wifi_txd,
  output        wifi_rxd,  // SPI from ESP32
  input         wifi_gpio16, // sclk
  input         wifi_gpio17, // cs
  output        wifi_gpio0,

  inout         sd_clk, sd_cmd,
  inout   [3:0] sd_d,

  output        sdram_csn,  // chip select
  output        sdram_clk,  // clock to SDRAM
  output        sdram_cke,  // clock enable to SDRAM
  output        sdram_rasn, // SDRAM RAS
  output        sdram_casn, // SDRAM CAS
  output        sdram_wen,  // SDRAM write-enable
  output [12:0] sdram_a,    // SDRAM address bus
  output  [1:0] sdram_ba,   // SDRAM bank-address
  output  [1:0] sdram_dqm,  // byte select
  inout  [15:0] sdram_d,    // data bus to/from SDRAM

  inout  [27:0] gp,gn,
  // SPI display
  output        oled_csn,
  output        oled_clk,
  output        oled_mosi,
  output        oled_dc,
  output        oled_resn,
  // Leds
  output [7:0]  leds
);

  // ===============================================================
  // System Clock generation
  // ===============================================================
  wire clk_sdram_locked;
  wire [3:0] clocks;

  ecp5pll
  #(
      .in_hz( 25*1000000),
    .out0_hz(135*1000000),
    .out1_hz( 27*1000000),
    .out2_hz(135*1000000),                // SDRAM core
    .out3_hz(135*1000000), .out3_deg(180) // SDRAM chip 45-330:ok 0-30:not
  )
  ecp5pll_inst
  (
    .clk_i(clk_25mhz),
    .clk_o(clocks),
    .locked(clk_sdram_locked)
  );

  wire clk_hdmi  = clocks[0];
  wire clk_vga   = clocks[1];
  wire clk_cpu   = clocks[1];
  wire clk_sdram = clocks[2];

  // ===============================================================
  // Reset generation
  // ===============================================================
  reg [15:0] pwr_up_reset_counter = 0;
  wire       pwr_up_reset_n = &pwr_up_reset_counter;
  reg [7:0]  R_cpu_control = 0; 

  always @(posedge clk_cpu) begin
     if (clk_sdram_locked && !pwr_up_reset_n)
       pwr_up_reset_counter <= pwr_up_reset_counter + 1;
  end

  wire reset = !pwr_up_reset_n || !btn[0] || R_cpu_control[0];

  // ===============================================================
  // Ulx3s-specific pin assignments
  // ===============================================================

  // Pull-ups for us2 connector
  assign usb_fpga_pu_dp = 1;
  assign usb_fpga_pu_dn = 1;

  assign wifi_rxd = ftdi_txd;
  assign ftdi_rxd = wifi_txd;

  // ===============================================================
  // Optional VGA output
  // ===============================================================
  wire   [7:0]  red;
  wire   [7:0]  green;
  wire   [7:0]  blue;
  wire          hSync;
  wire          vSync;

  // Pinout for Digilent VGA Pmod. Change for other pmods.
  generate
    genvar i;
    if (c_vga_out) begin
      for(i = 0; i < 4; i = i+1) begin
        assign gn[10-i] = red[4+i];
        assign gn[3-i] = green[4+i];
        assign gp[10-i] = blue[4+i];
      end
      assign gp[2] = vSync;
      assign gp[3] = hSync;
    end
  endgenerate

  // ===============================================================
  // Diagnostic leds
  // ===============================================================
  reg [15:0] diag16 = 0;

  generate
    genvar i;
    if (c_diag) begin
      for(i = 0; i < 4; i = i+1) begin
        assign gn[17-i] = diag16[8+i];
        assign gp[17-i] = diag16[12+i];
        assign gn[24-i] = diag16[i];
        assign gp[24-i] = diag16[4+i];
      end
    end
  endgenerate

  // ===============================================================
  // 68000 CPU
  // ===============================================================
  reg  fx68_phi1;                // Phi 1 enable
  reg  fx68_phi2;                // Phi 2 enable (for slow cpu)
  wire cpu_rw;                   // Read = 1, Write = 0
  wire cpu_as_n;                 // Address strobe
  wire cpu_lds_n;                // Lower byte
  wire cpu_uds_n;                // Upper byte
  wire cpu_E;                    // Peripheral enable
  wire vma_n;                    // Valid memory address
  wire vpa_n;                    // Valid peripheral address
  wire cpu_fc0;                  // Processor state
  wire cpu_fc1;
  wire cpu_fc2;
  reg  berr_n = 1'b1;            // Bus error.
  wire cpu_reset_n_o;            // Reset output signal
  reg  dtack_n = !vpa_n;         // Data transfer ack (always ready)
  wire bg_n;                     // Bus grant
  reg  bgack_n = 1'b1;           // Bus grant ack
  reg  vsync_irq;
  reg  ipl0_n = 1'b1;            // Interrupt request signals
  reg  ipl1_n = 1'b1;
  reg  ipl2_n = 1'b1;
  wire [15:0] ram_dout;
  wire [15:0] rom_dout;
  wire [15:0] vga_dout;
  wire [15:0] cpu_din;           // Data to CPU
  wire [15:0] cpu_dout;          // Data from CPU
  wire [23:1] cpu_a;             // Address
  wire [24:0] cpu_addr = {cpu_a, 1'b0};

  wire halt_n = ~R_cpu_control[2]; // prevent running SDRAM junk code
  wire ram_cs = (cpu_addr >= 24'h060000 && cpu_addr < 24'h062000);
  wire via_porta = (cpu_addr == 24'heffffe);

  assign vpa_n = !(cpu_addr >= 24'h800000);

  assign cpu_din = !vpa_n ? 0 : ram_cs ? ram_dout : rom_dout;

  // Generate phi1 and phi2 clock enables for the CPU
  generate
    if(c_slowdown)
    begin
      // Run 68k CPU SLOW
      reg [c_slowdown-1:0] delay_cnt;
      always @(posedge clk_cpu)
      begin
        fx68_phi1 <= delay_cnt == 0;
        fx68_phi2 <= delay_cnt == {1'b1,{(c_slowdown-1){1'b0}}};
        delay_cnt <= delay_cnt + 1;
      end
    end
    else // c_slowdown == 0, Run 68k CPU at 13.5 MHz
      always @(posedge clk_cpu)
      begin
        fx68_phi1 <= ~fx68_phi1;
        fx68_phi2 <=  fx68_phi1;
      end
  endgenerate

  fx68k fx68k (
    // input
    .clk( clk_cpu),
    .HALTn(halt_n),
    .extReset(reset),
    .pwrUp(!pwr_up_reset_n),
    .enPhi1(fx68_phi1),
    .enPhi2(fx68_phi2),

    // output
    .eRWn(cpu_rw),
    .ASn(cpu_as_n),
    .LDSn(cpu_lds_n),
    .UDSn(cpu_uds_n),
    .E(cpu_E),
    .VMAn(vma_n),
    .FC0(cpu_fc0),
    .FC1(cpu_fc1),
    .FC2(cpu_fc2),
    .BGn(bg_n),
    .oRESETn(cpu_reset_n_o),
    .oHALTEDn(),

    // input
    .DTACKn(dtack_n),
    .VPAn(vpa_n),
    .BERRn(berr_n),
    .BRn(~R_cpu_control[2]), // no bus request
    .BGACKn(1'b1),
    .IPL0n(ipl0_n),
    .IPL1n(ipl1_n),
    .IPL2n(ipl0_n), // ipl 0 and 2 tied together on the 68008

    // busses
    .iEdb(cpu_din),
    .oEdb(cpu_dout),
    .eab(cpu_a)
  );

  // ===============================================================
  // ROM
  // ===============================================================
  
  rom #(.MEM_INIT_FILE("../roms/macplus.mem")) rom_i (
    .clk(clk_cpu),
    .addr(cpu_a[16:1]),
    .dout(rom_dout)
  );

  // ===============================================================
  // SDRAM
  // ===============================================================

  sdram sdram_i (
    // cpu side
    .clk_in(clk_sdram),
    .rst (~clk_sdram_locked),
    .din (cpu_dout),
    .dout(ram_dout),
    .addr({1'b0, cpu_a[23:1]} - 24'h60000),
    .udsn(cpu_uds_n),
    .ldsn(cpu_lds_n),
    .asn (cpu_as_n),
    .rw  (cpu_rw || (cpu_a < 24'h60000)),

    // SDRAM side
    .sd_clk (sdram_clk),
    .sd_cke (sdram_cke),
    .sd_data(sdram_d),
    .sd_addr(sdram_a),
    .sd_dqm (sdram_dqm),
    .sd_ba  (sdram_ba),
    .sd_cs  (sdram_csn),
    .sd_we  (sdram_wen),
    .sd_ras (sdram_rasn),
    .sd_cas (sdram_casn)
  );

  // ===============================================================
  // Keyboard (not yet implemented)
  // ===============================================================
  wire [10:0] ps2_key;

  // Get PS/2 keyboard events
  ps2 ps2_kbd
  (
    .clk(clk_cpu),
    .ps2_clk(ps2Clk),
    .ps2_data(ps2Data),
    .ps2_key(ps2_key)
  );

  // ===============================================================
  // Video
  // ===============================================================
  wire [14:1] vid_addr; // Used by vdp
  wire [15:0] vid_dout; // Used by vdp
  wire        vid_cs = (cpu_addr >= c_screen_base && cpu_addr < c_screen_top);
  wire        vga_wr = !cpu_rw && vid_cs;
  wire        vga_de;
  wire [24:0] vga_addr = cpu_addr - c_screen_top; 

  vram video_ram (
    .clk_a(clk_cpu),
    .addr_a(vga_addr[13:1]),
    .we_a(vga_wr),
    .din_a(cpu_dout),
    .ub_a(!cpu_uds_n),
    .lb_a(!cpu_lds_n),
    .dout_a(vga_dout),
    .clk_b(clk_vga),
    .addr_b(vid_addr),
    .dout_b(vid_dout)
  );

  always @(posedge clk_cpu) begin
    diag16 <= {red, green};
  end

  video vga (
    .clk(clk_vga),
    .reset(reset),
    .vga_r(red),
    .vga_g(green),
    .vga_b(blue),
    .vga_de(vga_de),
    .vga_hs(hSync),
    .vga_vs(vSync),
    .vid_addr(vid_addr),
    .vid_dout(vid_dout)
  );

  // ===============================================================
  // Convert VGA to HDMI
  // ===============================================================
  HDMI_out vga2dvid (
    .pixclk(clk_vga),
    .pixclk_x5(clk_hdmi),
    .red  (red),
    .green(green),
    .blue (blue),
    .vde  (vga_de),
    .hSync(hSync),
    .vSync(vSync),
    .gpdi_dp(gpdi_dp),
    .gpdi_dn()
  );

  // ===============================================================
  // Diagnostic leds
  // ===============================================================
  assign leds = {!vpa_n, vid_cs, hSync, vSync, !cpu_rw, reset};

  generate
  if(c_lcd_hex)
  begin
  // SPI DISPLAY
  reg [127:0] R_display;
  // HEX decoder does printf("%16X\n%16X\n", R_display[63:0], R_display[127:64]);
  always @(posedge clk_cpu)
    R_display <= { 48'b0, rom_dout, // 2nd HEX row
                   8'b0, cpu_dout, cpu_din, cpu_a, 1'b0 }; // 1st HEX row
    //R_display = 128'h123456789abcdef0fedcba9876543210;

  parameter C_color_bits = 16;
  wire [7:0] x;
  wire [7:0] y;
  wire [C_color_bits-1:0] color;
  hex_decoder_v
  #(
    .c_data_len(128),
    .c_row_bits(4),
    .c_grid_6x8(1), // NOTE: TRELLIS needs -abc9 option to compile
    .c_font_file("hex_font.mem"),
    .c_color_bits(C_color_bits)
  )
  hex_decoder_v_inst
  (
    .clk(clk_hdmi),
    .data(R_display),
    .x(x[7:1]),
    .y(y[7:1]),
    .color(color)
  );

  // allow large combinatorial logic
  // to calculate color(x,y)
  wire next_pixel;
  reg [C_color_bits-1:0] R_color;
  always @(posedge clk_hdmi)
    if(next_pixel)
      R_color <= color;

  wire w_oled_csn;
  lcd_video
  #(
    .c_clk_mhz(125),
    .c_init_file("st7789_linit_xflip.mem"),
    .c_clk_phase(0),
    .c_clk_polarity(1),
    .c_init_size(38)
  )
  lcd_video_inst
  (
    .clk(clk_hdmi),
    .reset(btn[5]),
    .x(x),
    .y(y),
    .next_pixel(next_pixel),
    .color(R_color),
    .spi_clk(oled_clk),
    .spi_mosi(oled_mosi),
    .spi_dc(oled_dc),
    .spi_resn(oled_resn),
    .spi_csn(w_oled_csn)
  );
  //assign oled_csn = w_oled_csn; // 8-pin ST7789: oled_csn is connected to CSn
  assign oled_csn = 1; // 7-pin ST7789: oled_csn is connected to BLK (backlight enable pin)
  end
  endgenerate

endmodule
