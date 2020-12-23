`default_nettype none

`define INT_ONESEC              0
`define INT_VBLANK              1
`define INT_KEYREADY            2
`define INT_KEYBIT              3
`define INT_KEYCLK              4
`define INT_T2                  5
`define INT_T1                  6

// Mac 128k, Mac 512k or Mac Plus depending on parameters
module mac128
#(
  parameter c_slowdown    = 0, // CPU clock slowdown 2^n times (try 20-22)
  parameter c_lcd_hex     = 1, // SPI LCD HEX decoder
  parameter c_vga_out     = 0, // 0: Just HDMI, 1: VGA and HDMI
  parameter c_diag        = 1, // 0: No LED diagnostcs, 1: LED diagnostics
  parameter c_mhz         = 25000000, // Clock speed of CPU clock
  parameter c_screen_base = 24'h3fa700,
  parameter c_screen_top =  c_screen_base + 24'h5580,
  parameter c_init_file = "../roms/macplus.mem",
  parameter c_sound_buffer = 24'h3ffd00,
  parameter c_sound_len = 370
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
  inout         sd_cdn,

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
  output [7:0]  led
);

  // ===============================================================
  // System Clock generation
  // ===============================================================
  wire clk_sdram_locked;
  wire [3:0] clocks;

  ecp5pll
  #(
      .in_hz( 25*1000000),
    .out0_hz(125*1000000),
    .out1_hz( 25*1000000),
    .out2_hz(125*1000000),                // SDRAM core
    .out3_hz(125*1000000), .out3_deg(180) // Not used
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

  // Uart passthru to ESP32
  assign wifi_rxd = ftdi_txd;
  assign ftdi_rxd = wifi_txd;

  // ===============================================================
  // VGA output (output pins optional, if HDMI used)
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
  // Diagnostic leds using 2 Digilent 8 Led Pmods
  // ===============================================================
  reg [15:0] diag16;
  reg [15:0] debug;

  generate
    genvar i;
    if (c_diag) begin
      for(i = 0; i < 4; i = i+1) begin
        assign gn[10-i] = diag16[15-i];
        assign gp[10-i] = diag16[11-i];
        assign gn[3-i] = diag16[7-i];
        assign gp[3-i] = diag16[3-i];
      end
    end
  endgenerate

  // ===============================================================
  // 68000 CPU registers
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
  wire ipl0_n;                   // Interrupt request signals
  wire ipl1_n;
  wire ipl2_n;
  wire [15:0] ram_dout;
  //wire [15:0] low_ram_dout;
  wire [15:0] rom_dout;
  wire [15:0] cpu_din;                  // Data to CPU
  wire [15:0] cpu_dout;                 // Data from CPU
  wire [23:1] cpu_a;                    // 16-bit word address
  wire [23:0] cpu_addr = {cpu_a, 1'b0}; // Byte address
  reg [23:0]  last_rom_addr;
  wire        halt_n = ~R_cpu_control[2] && ~btn[1]; 
  reg         floppy_req_int, floppy_req_ext;
  // Chip select registers
  reg         via_cs, scc_cs, iwm_cs, scsi_cs, rom_cs, ram_cs;
  
  // Set auto-vectoring for interrupts
  assign      vpa_n = !(cpu_fc0 & cpu_fc1 & cpu_fc2);

  // ===============================================================
  // VIA registers
  // ===============================================================
  reg [7:0]   via_sr;                                                // Shift register
  reg [7:0]   via_acr;                                               // Auxilliary control register
  reg         kbd_out_strobe;                                        // Keyboard output strobe
  reg [7:0]   via_a_data_out, via_b_data_out;                        // Port A and B data
  reg         via_b0_ddr;
  reg [6:0]   via_ifr;                                               // Interupt flag register
  reg [6:0]   via_ier;                                               // Interupt enable register
  reg [15:0]  via_timer1_count, via_timer1_latch, via_timer2_count;  // Timer registers
  reg [7:0]   via_data_out_hi;
  reg [7:0]   via_timer2_latch_low;
  reg         via_timer2_armed;
  reg         rtc_data = 0;
  reg [5:0]   vsync_cnt;
  reg         old_vSync;

  wire        scc_wreq = 1;
  wire [7:0]  kbd_in_data;                                           // Keyboard input data
  wire        kbd_in_strobe;                                         // Keyboard input strobe
  wire        via_irq = (via_ifr & via_ier) != 0;
  wire        overlaid = !via_a_data_out[4];     // Set when ram and rom addresses changed
  wire [23:0] start_ram = overlaid ? 24'h0 : 24'h600000; // Start of ram
  wire [23:0] ram_addr = cpu_addr - start_ram;
  wire        mouse_x1, mouse_y1, mouse_x2, mouse_y2, mouse_button;
  wire [10:0] ps2_key;
  wire        capslock;

  // ===============================================================
  // SCC registers
  // ===============================================================
  reg         dcd_latch_a, dcd_latch_b;   // Latches for x1 and y1 mouse inputs
  reg [3:0]   rindex, rindex_latch;       // Index of register to read or write
  reg         latch_open_a, latch_open_b; // Indicate if dcd latches are open
  reg [7:0]   wr15_a, wr15_b;             // DCD interupt enable is bit 3
  reg [7:0]   wr1_a, wr1_b;               // External interrupt enable is bit 0
  reg [5:0]   wr9;                        // Master interrupt enable is bit 3 of WR9
  reg         ex_irq_ip_a, ex_irq_ip_b;   // Set for mouse interrupts

  wire        scc_irq = wr9[3] & (ex_irq_ip_a | ex_irq_ip_b);          // SCC interrupt active
  wire        scc8_cs = scc_cs && (cpu_lds_n == 0 || cpu_uds_n == 0);  // 8-bit SCC access
  wire [1:0]  rs = cpu_a[2:1];                                         // Inicates channel and cmd/data
  wire [7:0]  wdata = cpu_dout[15:8];                                  // Output data
  wire        wreg_a = scc8_cs & ~cpu_rw & ~rs[1] & rs[0];           // Channel A write request
  wire        wreg_b = scc8_cs & ~cpu_rw & ~rs[1] & ~rs[0];          // Channel B write request
  wire        do_extreset_a = wreg_a & (rindex == 0) & (wdata[5:3] == 3'b010); // Channel A interrupt reset request
  wire        do_extreset_b = wreg_b & (rindex == 0) & (wdata[5:3] == 3'b010); // Channel B interruptreset request
  wire        dcd_ip_a = (mouse_x1 != dcd_latch_a) & wr15_a[3];        // DCD A interrupt pending
  wire        dcd_ip_b = (mouse_y1 != dcd_latch_b) & wr15_b[3];        // DCD B interupt pending
  wire        do_latch_a = latch_open_a & dcd_ip_a;                    // Request latch of DCD A
  wire        do_latch_b = latch_open_b & dcd_ip_b;                    // Request latch of DCD B
  // Requests to reset SCC or just channel A or channel B
  wire        reset_scc = ((wreg_a | wreg_b) & (rindex == 9) & (wdata[7:6] == 2'b11)) | reset;
  wire        reset_a   = ((wreg_a | wreg_b) & (rindex == 9) & (wdata[7:6] == 2'b10)) | reset_scc;
  wire        reset_b   = ((wreg_a | wreg_b) & (rindex == 9) & (wdata[7:6] == 2'b01)) | reset_scc;
  wire [7:0]  rr0_a = {4'b0100, wr15_a[3] ? dcd_latch_a : mouse_x1, 3'b100};       // RR0A
  wire [7:0]  rr0_b = {4'b0100, wr15_b[3] ? dcd_latch_b : mouse_y1, 3'b100};       // RR0B
  wire [2:0]  rr_vec_stat = ex_irq_ip_a ? 3'b101 : ex_irq_ip_b ? 3'b001 : 3'b011;  // RR2B used to read external interrupt status
  wire [7:0]  rr2_b = {4'b0, rr_vec_stat, 1'b0};                                   // RR2B
  wire [7:0]  rr3_a = {4'b0, ex_irq_ip_a, 2'b0, ex_irq_ip_b};                      // RR3A
  wire [7:0]  rdata = rindex == 0 && rs[0] ? rr0_a :                               // Read data multiplexer
                      rindex == 0          ? rr0_b : 
                      rindex == 2 && rs[0] ? 0     :
                      rindex == 2          ? rr2_b :
                      rindex == 3 && rs[0] ? rr3_a : 0;

  // ===============================================================
  // IWM registers
  // ===============================================================
  wire        disk_sel = via_a_data_out[5];
  wire [15:0] iwm_dout;
  reg [1:0]   insert_disk;
  wire [1:0]  disk_in_drive;
  wire [15:0] track_buffer_addr;
  wire [7:0]  track_buffer_data;
  wire [6:0]  track_int, track_ext;
  wire [1:0]  side;
  reg [1:0]   stepping = 2'b11;

  // ===============================================================
  // Address decoding
  // ===============================================================
  always @(*) begin
    via_cs = 0;
    scc_cs = 0;
    iwm_cs = 0;
    scsi_cs = 0;
    ram_cs = 0;
    rom_cs = 0;

    casez(cpu_a[23:20]) 
      4'b00??: if (overlaid) ram_cs = 1;
               else rom_cs = 1;
      4'b0100: if (cpu_a[17] == 0) rom_cs = 1;
      4'b0101: if (cpu_a[19:12] == 8'h80) scsi_cs = 1;
      4'b0110: if (!overlaid) ram_cs = 1;
      4'b10?1: scc_cs = 1;
      4'b1101: iwm_cs = 1;
      4'b1110: via_cs = 1;
    endcase
  end

  // ===============================================================
  // VIA chip
  // ===============================================================
  
  // Set interrupt
  assign {ipl2_n, ipl1_n, ipl0_n} = via_irq ? 3'b110 : scc_irq ? 3'b101 : 3'b111;

  // VIA uses high byte
  wire [7:0] data_in_hi = cpu_dout[15:8];

  // Shift register for keyboard
  always @(posedge clk_cpu) begin
    if (reset) begin
      via_sr <= 0;
    end else begin
      if (via_cs && !cpu_rw && !cpu_uds_n && cpu_a[12:9] == 4'hA) via_sr <= data_in_hi;
      if (via_acr[4:2] == 3'b011 && kbd_in_strobe) via_sr <= kbd_in_data;
    end
  end

  // Generate keyboard out strobe 
  always @(posedge clk_cpu) begin
    if (reset) begin
      kbd_out_strobe <= 0;
    end else begin
      kbd_out_strobe = (via_cs && !cpu_rw && !cpu_uds_n && cpu_a[12:9] == 4'hA && via_acr[4:2] == 3'b111);
    end
  end

  wire load_t2 = via_cs && !cpu_rw && !cpu_uds_n && cpu_a[12:9] == 4'h9;

  // Diagnostics
  always @(posedge clk_cpu) begin
    if (reset) begin
      diag16 <= 0;
    end else begin
      //diag16 <= {side[1], track_ext, side[0], track_int};
      diag16 <= {capslock, kbd_out_strobe, kbd_in_strobe, via_sr};
      if (rom_cs) last_rom_addr <= cpu_addr;
    end
  end

  // VIA timer should be 1/10 of the clock speed = 1.25MHz
  reg [4:0] clk_div;
  wire timer_strobe = (clk_div == 0);
  always @(posedge clk_cpu) begin
    clk_div <= clk_div + 1; 
    if (clk_div == 19) clk_div <= 0;
  end

  // VIA register writes
  always @(posedge clk_cpu) begin
    if (reset) begin
      via_b0_ddr <= 1;
      via_a_data_out <= 8'b01111111;
      via_b_data_out <= 8'b11111111;
      via_ifr <= 0;
      via_ier <= 0;
      via_acr <= 0;
      via_timer1_count <= 0;
      via_timer1_latch <= 0;
      via_timer2_count <= 0;
      via_timer2_latch_low <= 0;
      via_timer2_armed <= 0;
    end else begin
      if (via_cs & !cpu_uds_n) begin
        if (!cpu_rw) begin // writes to VIA registers
          case(cpu_a[12:9])
            4'h0: via_b_data_out <= data_in_hi;                            // Port B
                                                                           // ???
            4'h2: via_b0_ddr <= data_in_hi[0];                             // Direction B
                                                                           // Direction A
            4'h4: via_timer1_count[7:0] <= data_in_hi;                     // Timer1 Count Lo
            4'h5: via_timer1_count[15:8] <= data_in_hi;                    // Timer1 Count Hi
            4'h6: via_timer1_latch[7:0] <= data_in_hi;                     // Timer1 Latch Lo
            4'h7: via_timer1_latch[15:8] <= data_in_hi;                    // Timer1 Latch Hi
            4'h8: via_timer2_latch_low <= data_in_hi;                      // Timer2_Count_Lo
            4'h9: begin                                                    // Timer2 Count Hi
                    via_timer2_count[15:8] <= data_in_hi;
                    via_timer2_count[7:0] <= via_timer2_latch_low;
                    via_timer2_armed <= 1;
                    via_ifr[`INT_T2] <= 0;
                  end
            4'hA: if (via_acr[4:2] == 3'b111) via_ifr[`INT_KEYREADY] <= 1; // Shift  Register
            4'hB: via_acr <= data_in_hi;                                   // Auxilliary Control Reg
                                                                           // Peripheral Control Reg
            4'hD: via_ifr <= via_ifr & ~data_in_hi[6:0];                   // Interrupt Flag Register
            4'hE: if (data_in_hi[7]) via_ier <= via_ier | data_in_hi[6:0]; // Interrupt Enable Register
                  else via_ier <= via_ier & ~data_in_hi[6:0];              
            4'hF: via_a_data_out <= data_in_hi;                            // Port A
          endcase
        end else begin // register reads triggering interrupts
          case (cpu_a[12:9])
            4'h0: begin
                    via_ifr[`INT_KEYCLK] <= 0;
                    via_ifr[`INT_KEYBIT] <= 0;
                  end
            4'h8: via_ifr[`INT_T2] <= 0;
            4'hA: via_ifr[`INT_KEYREADY] <= 0;
            4'hF: begin
                    via_ifr[`INT_ONESEC] <= 0;
                    via_ifr[`INT_VBLANK] <= 0;
                  end
          endcase
        end
      end
      // External interrupts
      old_vSync <= vSync;
      if (vSync == 0 & old_vSync == 1) begin
        via_ifr[`INT_VBLANK] <= 1;
        vsync_cnt <= vsync_cnt + 1;
        if (vsync_cnt == 59) begin
          via_ifr[`INT_ONESEC] <= 1;
          vsync_cnt <= 0;
        end
      end
      if (timer_strobe && !load_t2) begin
        if (via_timer2_armed && via_timer2_count == 0) begin
          via_ifr[`INT_T2] <= 1;
          via_timer2_armed <= 0;
        end
        via_timer2_count <= via_timer2_count -1;
      end
      if (via_acr[4:2] == 3'b011 && kbd_in_strobe) via_ifr[`INT_KEYREADY] <= 1;
    end
  end

  // VIA register read
  always @(8) begin
    via_data_out_hi = 8'hbe;

    case(cpu_a[12:9])
      4'h0: via_data_out_hi = {via_b_data_out[7], ~hSync, mouse_y2, mouse_x2, mouse_button, via_b_data_out[2:1], via_b0_ddr ? via_b_data_out[0] : rtc_data};
      4'h2: via_data_out_hi = {7'b1000011, via_b0_ddr};
      4'h3: via_data_out_hi = 8'b01111111;
      4'h4: via_data_out_hi = via_timer1_count[7:0];
      4'h5: via_data_out_hi = via_timer1_count[15:8];
      4'h6: via_data_out_hi = via_timer1_latch[7:0];
      4'h7: via_data_out_hi = via_timer1_latch[15:8];
      4'h8: via_data_out_hi = via_timer2_count[7:0];
      4'h9: via_data_out_hi = via_timer2_count[15:8];
      4'hA: via_data_out_hi = via_sr;
      4'hB: via_data_out_hi = via_acr;
      4'hC: via_data_out_hi = 0; // PCR
      4'hD: via_data_out_hi = {via_ifr & via_ier == 0, via_ifr};
      4'hE: via_data_out_hi = {1'b0, via_ier};
      4'hF: via_data_out_hi = {scc_wreq, via_a_data_out[6:0]};
    endcase
  end

  // ===============================================================
  // SCC
  // ===============================================================
  wire cep = fx68_phi1;
  wire cen = fx68_phi2;

  // Writes to registers 1 and 9. 9 shared between channels.
  always @(posedge clk_cpu) begin
    if (reset) begin
      wr9 <= 0;
      wr1_a <= 0;
      wr1_b <= 0;
    end else if (cen) begin
      if ((wreg_a || wreg_b) && (rindex == 9)) wr9 <= wdata[5:0];
      if (reset_a) wr1_a <= {2'b00, wr1_a[5], 2'b00, wr1_a[2], 2'b00}; // Don't resets bits 2 and 5
      else if (wreg_a && rindex == 1) wr1_a <= wdata;
      if (reset_b) wr1_b <= {2'b00, wr1_b[5], 2'b00, wr1_b[2], 2'b00}; // Don't reset bits 2 and 5
      else if (wreg_b && rindex == 1) wr1_b <= wdata;
    end
  end

  // Delay setting r_index from rindex_latch until end of read or write cycle
  always @(posedge clk_cpu) begin
    if (cen && cpu_as_n) rindex <= rindex_latch;
  end

  always @(posedge clk_cpu) begin
    if (reset_scc) begin
      rindex_latch <= 0;
      ex_irq_ip_a <= 0;
      ex_irq_ip_b <= 0;
      latch_open_a <= 1;
      latch_open_b <= 1;
      dcd_latch_a <= 0;
      dcd_latch_b <= 0;
      wr15_a <= 8'b11111000;
      wr15_b <= 8'b11111000;
    end else begin
      if (cen) begin
        // Set rindex_latch. r_index will be set of the next cycle.
        if (scc8_cs && !rs[1]) begin
          rindex_latch <= 0;
          if (!cpu_rw && rindex == 0) begin
            rindex_latch[2:0] <= wdata[2:0];
            rindex_latch[3] <= wdata[5:3] == 3'b001;
          end
        end
        // Register 15 just used for DCD interrupt enable
        if (rindex == 15) begin
          if (wreg_a) wr15_a <= wdata;
          if (wreg_b) wr15_b <= wdata;
        end
      end
      // Latch mouse inputs and request interrupts
      // do_extreset_a or _b reopens latch and resets interrupt
      if (cep) begin
        if (do_extreset_a) begin
          latch_open_a <= 1;
          ex_irq_ip_a <= 0;
        end else if (do_latch_a) begin
          latch_open_a <= 0;
          if (wr1_a[0]) ex_irq_ip_a <= 1;
        end
        if (do_extreset_b) begin
          latch_open_b <= 1;
          ex_irq_ip_b <= 0;
        end else if (do_latch_b) begin
          latch_open_b <= 0;
          if (wr1_b[0]) ex_irq_ip_b <= 1;
        end
        if (do_latch_a) dcd_latch_a <= mouse_x1;
        if (do_latch_b) dcd_latch_b <= mouse_y1;
      end
    end
  end

  // ===============================================================
  // IWM
  // ===============================================================
  iwm iwm_i (
    .clk(clk_cpu),
    ._reset(~reset),
    .cep(cep),
    .cen(cen),
    .selectIWM(iwm_cs),
    ._cpuRW(cpu_rw),
    ._cpuLDS(cpu_lds_n),
    .dataIn(cpu_dout),
    .cpuAddrRegHi(cpu_a[12:9]),
    .SEL(disk_sel),
    .dataOut(iwm_dout),
    .insertDisk(insert_disk),
    .diskInDrive(disk_in_drive),
    .trackBufferAddr(track_buffer_addr),
    .trackBufferData(track_buffer_data),
    .trackInt(track_int),
    .trackExt(track_ext),
    .side(side),
    .stepping(stepping)
  );

   
  reg [6:0] old_track_int, old_track_ext;
  always @(posedge clk_cpu) begin
    if (reset) begin
      floppy_req_int <= 0;
      floppy_req_ext <= 0;
    end else begin
      old_track_int <= track_int;
      floppy_req_int <= 0;
      if (track_int != old_track_int || insert_disk[0]) begin
        floppy_req_int <= 1;
      end
      old_track_ext <= track_ext;
      floppy_req_ext <= 0;
      if (track_ext != old_track_ext || insert_disk[1]) begin
        floppy_req_ext <= 1;
      end
    end
  end

  // ===============================================================
  // CPU
  // ===============================================================
  
  // CPU data in multiplexing
  assign cpu_din = via_cs ? {via_data_out_hi, 8'hEF} :   // VIA
                   scc8_cs ? {rdata, 8'hEF} :            // SCC for mouse
                   iwm_cs ? iwm_dout :
                   ram_cs ? ram_dout : 
                   rom_cs ? rom_dout : 0;

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
    .IPL2n(ipl2_n), 

    // busses
    .iEdb(cpu_din),
    .oEdb(cpu_dout),
    .eab(cpu_a)
  );

  // ===============================================================
  // ROM
  // ===============================================================
  
  // 128k rom for Mac Plus, 64k for Mac 128k
  rom #(.MEM_INIT_FILE(c_init_file)) rom_i (
    .clk(clk_cpu),
    .addr(cpu_a[16:1]),
    .dout(rom_dout)
  );

  // ====================================================
  // Joystick for OSD control and games
  // ===============================================================
  reg [6:0] R_btn_joy;
  always @(posedge clk_cpu)
    R_btn_joy <= btn;

  // ===============================================================
  // SPI Slave for RAM and CPU control
  // ===============================================================
  wire        spi_ram_wr, spi_ram_rd;
  wire [31:0] spi_ram_addr;
  wire  [7:0] spi_floppy_do = 0;
  wire  [7:0] spi_ram_di = spi_ram_addr[31:24]==8'hD1 ? spi_floppy_do : (spi_ram_addr[0] ? ram_dout[7:0] : ram_dout[15:8]);
  wire  [7:0] spi_ram_do;

  //assign sd_d[0] = 1'bz;
  //assign sd_d[3] = 1'bz; // FPGA pin pullup sets SD card inactive at SPI bus
  assign sd_cdn = sd_clk|sd_cmd|(|sd_d); // force usage to activate pull-up required for 4-bit SD mode

  wire spi_irq;
  spi_ram_btn
  #(
    .c_sclk_capable_pin(1'b0),
    .c_addr_bits(32)
  )
  spi_ram_btn_inst
  (
    .clk(clk_cpu),
    .csn(~wifi_gpio17),
    .sclk(wifi_gpio16),
    //.mosi(sd_d[1]), // wifi_gpio4
    //.miso(sd_d[2]), // wifi_gpio12
    .mosi(gn[11]), // wifi_gpio25
    .miso(gp[11]), // wifi_gpio26
    .btn(R_btn_joy),
    .irq(spi_irq),
    .floppy_req(floppy_req_int | floppy_req_ext),
    .floppy_req_type({floppy_req_ext, floppy_req_ext ? track_ext : track_int}),
    .floppy_in_drive(disk_in_drive),
    .wr(spi_ram_wr),
    .rd(spi_ram_rd),
    .addr(spi_ram_addr),
    .data_in(spi_ram_di),
    .data_out(spi_ram_do)
  );

  wire disk_ram_write = spi_ram_wr && spi_ram_addr[31:24] == 8'hD1;
  ram8 ram_disk (
    .clk(clk_cpu),
    .we(disk_ram_write),
    .addr(disk_ram_write ? spi_ram_addr : track_buffer_addr),
    .dout(track_buffer_data),
    .din(spi_ram_do)
  );

  // Used for interrupt to ESP32
  assign wifi_gpio0 = ~spi_irq;

  reg [7:0] R_spi_ram_byte[0:1];
  reg R_spi_ram_wr;
  reg spi_ram_word_wr;
  always @(posedge clk_cpu) begin
    if (reset) begin
      insert_disk <= 2'b00;
    end else begin
      R_spi_ram_wr <= spi_ram_wr;
      if(spi_ram_wr == 1'b1) begin
        if(spi_ram_addr[31:24] == 8'hFF) begin
          R_cpu_control <= spi_ram_do;
          insert_disk <= spi_ram_do[5:4]; // values 16 and 32 for floppies 1 and 2
        end else
          R_spi_ram_byte[spi_ram_addr[0]] <= spi_ram_do;
        if(R_spi_ram_wr == 1'b0) begin
          if(spi_ram_addr[31:24] == 8'h00 && spi_ram_addr[0] == 1'b1)
            spi_ram_word_wr <= 1'b1;
        end
      end else
        spi_ram_word_wr <= 1'b0;
    end
  end
  wire [15:0] ram_di = { R_spi_ram_byte[0], R_spi_ram_byte[1] }; // to SDRAM chip

  // ===============================================================
  // SDRAM
  // ===============================================================

  wire we = spi_ram_word_wr;
  wire re = spi_ram_addr[31:24] == 8'h00 ? spi_ram_rd : 1'b0;
  sdram sdram_i (
    // cpu side
    .clk_in(clk_sdram),
    .rst (~clk_sdram_locked),
    .din (R_cpu_control[1] ? ram_di : cpu_dout),
    .dout(ram_dout),
    .addr(R_cpu_control[1] ? {1'b0, spi_ram_addr[23:1]} : {1'b0, ram_addr[23:1]}),
    .udsn(R_cpu_control[1] ? ~(we|re) : cpu_uds_n),
    .ldsn(R_cpu_control[1] ? ~(we|re) : cpu_lds_n),
    .asn (R_cpu_control[1] ? ~(we|re) : cpu_as_n),
    .rw  (R_cpu_control[1] ? ~we      : cpu_rw || !ram_cs),

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
  // Keyboard
  // ===============================================================

  assign gp[22] = 1'b1;
  assign gn[22] = 1'b1;

  // Get PS/2 keyboard events
  ps2key ps2key_i (
    .clk(clk_cpu),
    .ps2_clk(gp[21]),
    .ps2_data(gn[21]),
    .ps2_key(ps2_key)
  );

  ps2_kbd ps2_kbd_i (
    .clk(clk_cpu),
    .reset(reset),
    .ce(cep),
    .ps2_key(ps2_key),
    .capslock(capslock),
    .data_out(via_sr),
    .strobe_out(kbd_out_strobe),
    .data_in(kbd_in_data),
    .strobe_in(kbd_in_strobe)
  );

  // ===============================================================
  // Mouse
  // ===============================================================
  ps2_mouse ps2_mouse_i (
    .sysclk(clk_cpu),
    .reset(reset),
    .x1(mouse_x1),
    .x2(mouse_x2),
    .y1(mouse_y1),
    .y2(mouse_y2),
    .button(mouse_button),
    .ps2dat(ps2Data),
    .ps2clk(ps2Clk),
    .debug(debug)
  );
  
  // ===============================================================
  // Video
  // ===============================================================
  wire [14:1] vid_b_addr; 
  wire [15:0] vid_b_dout; 
  wire [15:0] vid_a_dout;
  wire        vid_cs = (ram_addr >= c_screen_base) && (ram_addr < c_screen_top);
  wire        vid_a_wr = (cpu_rw == 0) && vid_cs;
  wire        vga_de;
  wire [23:0] vid_a_addr = ram_addr - c_screen_base;

  vram video_ram (
    .clk_a(clk_cpu),
    .addr_a(vid_a_addr[14:1]),
    .we_a(vid_a_wr),
    .din_a(cpu_dout),
    .ub_a(!cpu_uds_n),
    .lb_a(!cpu_lds_n),
    .dout_a(vid_a_dout),
    .clk_b(clk_vga),
    .addr_b(vid_b_addr),
    .dout_b(vid_b_dout)
  );

  video vga (
    .clk(clk_vga),
    .reset(reset),
    .vga_r(red),
    .vga_g(green),
    .vga_b(blue),
    .vga_de(vga_de),
    .vga_hs(hSync),
    .vga_vs(vSync),
    .vid_addr(vid_b_addr),
    .vid_dout(vid_b_dout)
  );

  // ===============================================================
  // Audio 
  // ===============================================================

  reg [10:0] audio_cnt;
  reg [8:0]  audio_addr;
  wire [7:0] audio_dout;
  wire audio_cs = (cpu_addr >= c_sound_buffer) && (cpu_addr < (c_sound_buffer + (c_sound_len * 2)));
  wire [9:0] snd_addr = cpu_addr - c_sound_buffer;

  // Dual port RAM for audio buffer, mirrors sound bytes from sound buffer
  audio_ram audio_ram_i (
    .clk(clk_cpu),
    .we(audio_cs && !cpu_rw && !cpu_uds_n),
    .waddr(snd_addr[9:1]),
    .raddr(audio_addr),
    .din(cpu_dout[15:8] - 128), // Store signed value
    .dout(audio_dout)
  );

  // Increment the audio read address 370 times per video frame
  always @(posedge clk_cpu) begin
    audio_cnt <= audio_cnt + 1;
    if (vSync == 0 && old_vSync == 1) begin
      audio_cnt <= 0;
      audio_addr <= 0;
    end
    if (audio_cnt == 1125) begin
      audio_cnt <= 0;
      audio_addr <= audio_addr + 1;
      if (audio_addr == c_sound_len -1) audio_addr <= 0;
    end
  end

  // Use sigma-delta dac to get single-bit output
  wire aud_l, aud_r;
  wire [10:0] audio = {{3{audio_dout[7]}}, audio_dout}; // Sign extend to 11 bits
  sigma_delta_dac dac (
    .clk(clk_cpu),
    .ldatasum({audio, 4'b0}), // Extend to 14 bits
    .rdatasum({audio, 4'b0}),
    .left(aud_l),
    .right(aud_r)
  );

  // Use VIA sound enable and volume
  assign audio_l = via_b_data_out[7] == 0 ? (aud_l ? {via_a_data_out[2:0], 1'b0} : 0) : 0;
  assign audio_r = audio_l;

  // ===============================================================
  // SPI Slave for OSD display
  // ===============================================================
  wire [7:0] osd_vga_r, osd_vga_g, osd_vga_b;
  wire osd_vga_hsync, osd_vga_vsync, osd_vga_blank;
  spi_osd
  #(
    .c_start_x(62), .c_start_y(80),
    .c_chars_x(64), .c_chars_y(20),
    .c_init_on(0),
    .c_transparency(1),
    .c_char_file("osd.mem"),
    .c_font_file("font_bizcat8x16.mem")
  )
  spi_osd_inst
  (
    .clk_pixel(clk_vga), .clk_pixel_ena(1),
    .i_r(red  ),
    .i_g(green),
    .i_b(blue ),
    .i_hsync(~hSync), .i_vsync(~vSync), .i_blank(~vga_de),
    .i_csn(~wifi_gpio17), .i_sclk(wifi_gpio16),
    //.i_mosi(sd_d[1]), // wifi_gpio4
    .i_mosi(gn[11]), // wifi_gpio25
    // .o_miso(),
    .o_r(osd_vga_r), .o_g(osd_vga_g), .o_b(osd_vga_b),
    .o_hsync(osd_vga_hsync), .o_vsync(osd_vga_vsync), .o_blank(osd_vga_blank)
  );

  // ===============================================================
  // Convert VGA to HDMI
  // ===============================================================
  HDMI_out vga2dvid (
    .pixclk(clk_vga),
    .pixclk_x5(clk_hdmi),
    .red  (osd_vga_r),
    .green(osd_vga_g),
    .blue (osd_vga_b),
    .vde  (~osd_vga_blank),
    .hSync(~osd_vga_hsync),
    .vSync(~osd_vga_vsync),
    .gpdi_dp(gpdi_dp),
    .gpdi_dn()
  );

  // ===============================================================
  // Diagnostic leds and lcd
  // ===============================================================
  assign led = {scc_irq, via_irq, mouse_button, mouse_y2, insert_disk, disk_in_drive};

  generate
  if(c_lcd_hex)
  begin
  // SPI DISPLAY
  reg [127:0] R_display;
  // HEX decoder does printf("%16X\n%16X\n", R_display[63:0], R_display[127:64]);
  always @(posedge clk_cpu)
    R_display <= { 8'b0, ram_dout, rom_dout, last_rom_addr, // 2nd HEX row
                   8'b0, cpu_dout, cpu_din, cpu_addr}; // 1st HEX row

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

