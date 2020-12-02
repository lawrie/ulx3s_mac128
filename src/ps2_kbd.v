`timescale 1ns / 100ps

/*
 * PS2 Keyboard to Mac interface module
 */
module ps2_kbd
(
	input	clk,
	input	ce,

	input	reset,

	input [10:0] ps2_key,
	output reg   capslock,
	 
	input  [7:0] data_out,
	input	 strobe_out,

	output [7:0] data_in,
	output 	 strobe_in
);

reg   [8:0] keymac;
reg	    key_pending;
reg  [21:0] pacetimer;
reg	    inquiry_active;
reg         cmd_inquiry;
reg 	    cmd_instant;
reg 	    cmd_model;
reg 	    cmd_test;

/* Latch commands from Mac */
always@(posedge clk or posedge reset) begin
	if (reset) begin
		cmd_inquiry <= 0;
		cmd_instant <= 0;
		cmd_model <= 0;
		cmd_test <= 0;
	end else if(ce) begin
		if (strobe_out) begin
			cmd_inquiry <= 0;
			cmd_instant <= 0;
			cmd_model <= 0;
			cmd_test <= 0;
			case(data_out)
				8'h10: cmd_inquiry <= 1;
				8'h14: cmd_instant <= 1;
				8'h16: cmd_model   <= 1;
				8'h36: cmd_test    <= 1;
			endcase
		end
	end
end

/* Divide our clock to pace our responses to the Mac. tick_short ticks
 * when we can respond to a command, and tick_long ticks when an inquiry
 * command shall timeout
 */
always@(posedge clk or posedge reset) begin
	if (reset)
		pacetimer <= 0;
	else if(ce) begin
	        /* reset counter on command from Mac */
		if (strobe_out)
			pacetimer <= 0;		  
		else if (!tick_long)
			pacetimer <= pacetimer + 1'd1;
	end
end

wire tick_long  = pacetimer == 22'h3fffff;
wire tick_short = pacetimer == 22'h000fff;

/* Delay inquiry responses to after tick_short */
always@(posedge clk or posedge reset) begin
	if (reset)
		inquiry_active <= 0;
	else if(ce) begin
		if (strobe_out | strobe_in)
			inquiry_active <= 0;
		else if (tick_short)
			inquiry_active <= cmd_inquiry;		  
	end	
end

wire pop_key = (cmd_instant & tick_short) | (inquiry_active & tick_long) | (inquiry_active & key_pending);

/* Reply to Mac */
assign strobe_in = ((cmd_model | cmd_test) & tick_short) | pop_key;	

/* Data to Mac */
assign data_in = cmd_test 	? 8'h7d :
		 cmd_model	? 8'h03 :
		 key_pending ? (keymac[8] ? 8'h79 : keymac[7:0]) : 
		 8'h7b;	

wire depress  = ~ps2_key[9];
wire extended = ps2_key[8];
wire ignore_capslock = {extended,ps2_key[7:0]} == 9'h058 && capslock;

/* Handle key_pending, and multi-byte keypad responses */
reg old_stb;
always @(posedge clk) begin

	if (reset) begin
		key_pending <= 0;
		old_stb <= ps2_key[10];
		capslock <= 0;
	end
	else if(ce) begin
		if (cmd_model | cmd_test) key_pending <= 0;
		else if (pop_key) begin
			if (keymac[8]) keymac[8] <= 0;
			else key_pending <= 0;
		end else begin
	
			old_stb <= ps2_key[10];
			if(old_stb != ps2_key[10]) begin

			        /* Capslock handling */
				if(ps2_key[7:0] == 8'h58 && !extended && !depress) capslock <= ~capslock;
				
				if(!key_pending && !ignore_capslock) begin
					key_pending <= 1;
					keymac <= {key_code[8],depress,key_code[6:0]};
				end
			end
		end
	end
end


//use BRAM for table
wire [8:0] key_code = code[key_addr];
reg  [8:0] key_addr;
always @(posedge clk) key_addr <= {extended,ps2_key[7:0]};

wire [8:0] code[512];

assign code[9'h000] = 9'h07b;
assign code[9'h001] = 9'h07b;  //F9
assign code[9'h002] = 9'h07b;
assign code[9'h003] = 9'h07b;  //F5
assign code[9'h004] = 9'h07b;  //F3
assign code[9'h005] = 9'h07b;  //F1
assign code[9'h006] = 9'h07b;  //F2
assign code[9'h007] = 9'h07b;  //F12 <OSD>
assign code[9'h008] = 9'h07b;
assign code[9'h009] = 9'h07b;  //F10
assign code[9'h00a] = 9'h07b;  //F8
assign code[9'h00b] = 9'h07b;  //F6
assign code[9'h00c] = 9'h07b;  //F4
assign code[9'h00d] = 9'h061;  //TAB
assign code[9'h00e] = 9'h065;  //~ (`)
assign code[9'h00f] = 9'h07b;
assign code[9'h010] = 9'h07b;
assign code[9'h011] = 9'h06f;  //LEFT ALT (command)
assign code[9'h012] = 9'h071;  //LEFT SHIFT
assign code[9'h013] = 9'h07b;
assign code[9'h014] = 9'h07b;  //CTRL (not mapped)
assign code[9'h015] = 9'h019;  //q
assign code[9'h016] = 9'h025;  //1
assign code[9'h017] = 9'h07b;
assign code[9'h018] = 9'h07b;
assign code[9'h019] = 9'h07b;
assign code[9'h01a] = 9'h00d;  //z
assign code[9'h01b] = 9'h003;  //s
assign code[9'h01c] = 9'h001;  //a
assign code[9'h01d] = 9'h01b;  //w
assign code[9'h01e] = 9'h027;  //2
assign code[9'h01f] = 9'h07b;
assign code[9'h020] = 9'h07b;
assign code[9'h021] = 9'h011;  //c
assign code[9'h022] = 9'h00f;  //x
assign code[9'h023] = 9'h005;  //d
assign code[9'h024] = 9'h01d;  //e
assign code[9'h025] = 9'h02b;  //4
assign code[9'h026] = 9'h029;  //3
assign code[9'h027] = 9'h07b;
assign code[9'h028] = 9'h07b;
assign code[9'h029] = 9'h063;  //SPACE
assign code[9'h02a] = 9'h013;  //v
assign code[9'h02b] = 9'h007;  //f
assign code[9'h02c] = 9'h023;  //t
assign code[9'h02d] = 9'h01f;  //r
assign code[9'h02e] = 9'h02f;  //5
assign code[9'h02f] = 9'h07b;
assign code[9'h030] = 9'h07b;
assign code[9'h031] = 9'h05b;  //n
assign code[9'h032] = 9'h017;  //b
assign code[9'h033] = 9'h009;  //h
assign code[9'h034] = 9'h00b;  //g
assign code[9'h035] = 9'h021;  //y
assign code[9'h036] = 9'h02d;  //6
assign code[9'h037] = 9'h07b;
assign code[9'h038] = 9'h07b;
assign code[9'h039] = 9'h07b;
assign code[9'h03a] = 9'h05d;  //m
assign code[9'h03b] = 9'h04d;  //j
assign code[9'h03c] = 9'h041;  //u
assign code[9'h03d] = 9'h035;  //7
assign code[9'h03e] = 9'h039;  //8
assign code[9'h03f] = 9'h07b;
assign code[9'h040] = 9'h07b;
assign code[9'h041] = 9'h057;  //<;
assign code[9'h042] = 9'h051;  //k
assign code[9'h043] = 9'h045;  //i
assign code[9'h044] = 9'h03f;  //o
assign code[9'h045] = 9'h03b;  //0
assign code[9'h046] = 9'h033;  //9
assign code[9'h047] = 9'h07b;
assign code[9'h048] = 9'h07b;
assign code[9'h049] = 9'h05f;  //>.
assign code[9'h04a] = 9'h059;  //FORWARD SLASH
assign code[9'h04b] = 9'h04b;  //l
assign code[9'h04c] = 9'h053;  //;
assign code[9'h04d] = 9'h047;  //p
assign code[9'h04e] = 9'h037;  //-
assign code[9'h04f] = 9'h07b;
assign code[9'h050] = 9'h07b;
assign code[9'h051] = 9'h07b;
assign code[9'h052] = 9'h04f;  //'"
assign code[9'h053] = 9'h07b;
assign code[9'h054] = 9'h043;  //[
assign code[9'h055] = 9'h031;  // = 
assign code[9'h056] = 9'h07b;
assign code[9'h057] = 9'h07b;
assign code[9'h058] = 9'h073;  //CAPSLOCK
assign code[9'h059] = 9'h071;  //RIGHT SHIFT
assign code[9'h05a] = 9'h049;  //ENTER
assign code[9'h05b] = 9'h03d;  //]
assign code[9'h05c] = 9'h07b;
assign code[9'h05d] = 9'h055;  //BACKSLASH
assign code[9'h05e] = 9'h07b;
assign code[9'h05f] = 9'h07b;
assign code[9'h060] = 9'h07b;
assign code[9'h061] = 9'h071;  //international left shift cut out (German '<>' key), 0x56 Set#1 code
assign code[9'h062] = 9'h07b;
assign code[9'h063] = 9'h07b;
assign code[9'h064] = 9'h07b;
assign code[9'h065] = 9'h07b;
assign code[9'h066] = 9'h067;  //BACKSPACE
assign code[9'h067] = 9'h07b;
assign code[9'h068] = 9'h07b;
assign code[9'h069] = 9'h127;  //KP 1
assign code[9'h06a] = 9'h07b;
assign code[9'h06b] = 9'h12d;  //KP 4
assign code[9'h06c] = 9'h133;  //KP 7
assign code[9'h06d] = 9'h07b;
assign code[9'h06e] = 9'h07b;
assign code[9'h06f] = 9'h07b;
assign code[9'h070] = 9'h125;  //KP 0
assign code[9'h071] = 9'h103;  //KP .
assign code[9'h072] = 9'h129;  //KP 2
assign code[9'h073] = 9'h12f;  //KP 5
assign code[9'h074] = 9'h131;  //KP 6
assign code[9'h075] = 9'h137;  //KP 8
assign code[9'h076] = 9'h07b;  //ESCAPE
assign code[9'h077] = 9'h07b;  //NUMLOCK (Mac keypad clear?)
assign code[9'h078] = 9'h07b;  //F11 <OSD>
assign code[9'h079] = 9'h10d;  //KP +
assign code[9'h07a] = 9'h12b;  //KP 3
assign code[9'h07b] = 9'h11d;  //KP -
assign code[9'h07c] = 9'h105;  //KP *
assign code[9'h07d] = 9'h139;  //KP 9
assign code[9'h07e] = 9'h07b;  //SCROLL LOCK / KP )
assign code[9'h07f] = 9'h07b;
assign code[9'h080] = 9'h07b;
assign code[9'h081] = 9'h07b;
assign code[9'h082] = 9'h07b;
assign code[9'h083] = 9'h07b;  //F7
assign code[9'h084] = 9'h07b;
assign code[9'h085] = 9'h07b;
assign code[9'h086] = 9'h07b;
assign code[9'h087] = 9'h07b;
assign code[9'h088] = 9'h07b;
assign code[9'h089] = 9'h07b;
assign code[9'h08a] = 9'h07b;
assign code[9'h08b] = 9'h07b;
assign code[9'h08c] = 9'h07b;
assign code[9'h08d] = 9'h07b;
assign code[9'h08e] = 9'h07b;
assign code[9'h08f] = 9'h07b;
assign code[9'h090] = 9'h07b;
assign code[9'h091] = 9'h07b;
assign code[9'h092] = 9'h07b;
assign code[9'h093] = 9'h07b;
assign code[9'h094] = 9'h07b;
assign code[9'h095] = 9'h07b;
assign code[9'h096] = 9'h07b;
assign code[9'h097] = 9'h07b;
assign code[9'h098] = 9'h07b;
assign code[9'h099] = 9'h07b;
assign code[9'h09a] = 9'h07b;
assign code[9'h09b] = 9'h07b;
assign code[9'h09c] = 9'h07b;
assign code[9'h09d] = 9'h07b;
assign code[9'h09e] = 9'h07b;
assign code[9'h09f] = 9'h07b;
assign code[9'h0a0] = 9'h07b;
assign code[9'h0a1] = 9'h07b;
assign code[9'h0a2] = 9'h07b;
assign code[9'h0a3] = 9'h07b;
assign code[9'h0a4] = 9'h07b;
assign code[9'h0a5] = 9'h07b;
assign code[9'h0a6] = 9'h07b;
assign code[9'h0a7] = 9'h07b;
assign code[9'h0a8] = 9'h07b;
assign code[9'h0a9] = 9'h07b;
assign code[9'h0aa] = 9'h07b;
assign code[9'h0ab] = 9'h07b;
assign code[9'h0ac] = 9'h07b;
assign code[9'h0ad] = 9'h07b;
assign code[9'h0ae] = 9'h07b;
assign code[9'h0af] = 9'h07b;
assign code[9'h0b0] = 9'h07b;
assign code[9'h0b1] = 9'h07b;
assign code[9'h0b2] = 9'h07b;
assign code[9'h0b3] = 9'h07b;
assign code[9'h0b4] = 9'h07b;
assign code[9'h0b5] = 9'h07b;
assign code[9'h0b6] = 9'h07b;
assign code[9'h0b7] = 9'h07b;
assign code[9'h0b8] = 9'h07b;
assign code[9'h0b9] = 9'h07b;
assign code[9'h0ba] = 9'h07b;
assign code[9'h0bb] = 9'h07b;
assign code[9'h0bc] = 9'h07b;
assign code[9'h0bd] = 9'h07b;
assign code[9'h0be] = 9'h07b;
assign code[9'h0bf] = 9'h07b;
assign code[9'h0c0] = 9'h07b;
assign code[9'h0c1] = 9'h07b;
assign code[9'h0c2] = 9'h07b;
assign code[9'h0c3] = 9'h07b;
assign code[9'h0c4] = 9'h07b;
assign code[9'h0c5] = 9'h07b;
assign code[9'h0c6] = 9'h07b;
assign code[9'h0c7] = 9'h07b;
assign code[9'h0c8] = 9'h07b;
assign code[9'h0c9] = 9'h07b;
assign code[9'h0ca] = 9'h07b;
assign code[9'h0cb] = 9'h07b;
assign code[9'h0cc] = 9'h07b;
assign code[9'h0cd] = 9'h07b;
assign code[9'h0ce] = 9'h07b;
assign code[9'h0cf] = 9'h07b;
assign code[9'h0d0] = 9'h07b;
assign code[9'h0d1] = 9'h07b;
assign code[9'h0d2] = 9'h07b;
assign code[9'h0d3] = 9'h07b;
assign code[9'h0d4] = 9'h07b;
assign code[9'h0d5] = 9'h07b;
assign code[9'h0d6] = 9'h07b;
assign code[9'h0d7] = 9'h07b;
assign code[9'h0d8] = 9'h07b;
assign code[9'h0d9] = 9'h07b;
assign code[9'h0da] = 9'h07b;
assign code[9'h0db] = 9'h07b;
assign code[9'h0dc] = 9'h07b;
assign code[9'h0dd] = 9'h07b;
assign code[9'h0de] = 9'h07b;
assign code[9'h0df] = 9'h07b;
assign code[9'h0e0] = 9'h07b;  //ps2 extended key
assign code[9'h0e1] = 9'h07b;
assign code[9'h0e2] = 9'h07b;
assign code[9'h0e3] = 9'h07b;
assign code[9'h0e4] = 9'h07b;
assign code[9'h0e5] = 9'h07b;
assign code[9'h0e6] = 9'h07b;
assign code[9'h0e7] = 9'h07b;
assign code[9'h0e8] = 9'h07b;
assign code[9'h0e9] = 9'h07b;
assign code[9'h0ea] = 9'h07b;
assign code[9'h0eb] = 9'h07b;
assign code[9'h0ec] = 9'h07b;
assign code[9'h0ed] = 9'h07b;
assign code[9'h0ee] = 9'h07b;
assign code[9'h0ef] = 9'h07b;
assign code[9'h0f0] = 9'h07b;  //ps2 release code
assign code[9'h0f1] = 9'h07b;
assign code[9'h0f2] = 9'h07b;
assign code[9'h0f3] = 9'h07b;
assign code[9'h0f4] = 9'h07b;
assign code[9'h0f5] = 9'h07b;
assign code[9'h0f6] = 9'h07b;
assign code[9'h0f7] = 9'h07b;
assign code[9'h0f8] = 9'h07b;
assign code[9'h0f9] = 9'h07b;
assign code[9'h0fa] = 9'h07b;  //ps2 ack code
assign code[9'h0fb] = 9'h07b;
assign code[9'h0fc] = 9'h07b;
assign code[9'h0fd] = 9'h07b;
assign code[9'h0fe] = 9'h07b;
assign code[9'h0ff] = 9'h07b;
assign code[9'h100] = 9'h07b;
assign code[9'h101] = 9'h07b;
assign code[9'h102] = 9'h07b;
assign code[9'h103] = 9'h07b;
assign code[9'h104] = 9'h07b;
assign code[9'h105] = 9'h07b;
assign code[9'h106] = 9'h07b;
assign code[9'h107] = 9'h07b;
assign code[9'h108] = 9'h07b;
assign code[9'h109] = 9'h07b;
assign code[9'h10a] = 9'h07b;
assign code[9'h10b] = 9'h07b;
assign code[9'h10c] = 9'h07b;
assign code[9'h10d] = 9'h07b;
assign code[9'h10e] = 9'h07b;
assign code[9'h10f] = 9'h07b;
assign code[9'h110] = 9'h07b;
assign code[9'h111] = 9'h06f;  //RIGHT ALT (command)
assign code[9'h112] = 9'h07b;
assign code[9'h113] = 9'h07b;
assign code[9'h114] = 9'h07b;
assign code[9'h115] = 9'h07b;
assign code[9'h116] = 9'h07b;
assign code[9'h117] = 9'h07b;
assign code[9'h118] = 9'h07b;
assign code[9'h119] = 9'h07b;
assign code[9'h11a] = 9'h07b;
assign code[9'h11b] = 9'h07b;
assign code[9'h11c] = 9'h07b;
assign code[9'h11d] = 9'h07b;
assign code[9'h11e] = 9'h07b;
assign code[9'h11f] = 9'h075;  //WINDOWS OR APPLICATION KEY (option)
assign code[9'h120] = 9'h07b;
assign code[9'h121] = 9'h07b;
assign code[9'h122] = 9'h07b;
assign code[9'h123] = 9'h07b;
assign code[9'h124] = 9'h07b;
assign code[9'h125] = 9'h07b;
assign code[9'h126] = 9'h07b;
assign code[9'h127] = 9'h07b;
assign code[9'h128] = 9'h07b;
assign code[9'h129] = 9'h07b;
assign code[9'h12a] = 9'h07b;
assign code[9'h12b] = 9'h07b;
assign code[9'h12c] = 9'h07b;
assign code[9'h12d] = 9'h07b;
assign code[9'h12e] = 9'h07b;
assign code[9'h12f] = 9'h07b;
assign code[9'h130] = 9'h07b;
assign code[9'h131] = 9'h07b;
assign code[9'h132] = 9'h07b;
assign code[9'h133] = 9'h07b;
assign code[9'h134] = 9'h07b;
assign code[9'h135] = 9'h07b;
assign code[9'h136] = 9'h07b;
assign code[9'h137] = 9'h07b;
assign code[9'h138] = 9'h07b;
assign code[9'h139] = 9'h07b;
assign code[9'h13a] = 9'h07b;
assign code[9'h13b] = 9'h07b;
assign code[9'h13c] = 9'h07b;
assign code[9'h13d] = 9'h07b;
assign code[9'h13e] = 9'h07b;
assign code[9'h13f] = 9'h07b;
assign code[9'h140] = 9'h07b;
assign code[9'h141] = 9'h07b;
assign code[9'h142] = 9'h07b;
assign code[9'h143] = 9'h07b;
assign code[9'h144] = 9'h07b;
assign code[9'h145] = 9'h07b;
assign code[9'h146] = 9'h07b;
assign code[9'h147] = 9'h07b;
assign code[9'h148] = 9'h07b;
assign code[9'h149] = 9'h07b;
assign code[9'h14a] = 9'h11b;  //KP /
assign code[9'h14b] = 9'h07b;
assign code[9'h14c] = 9'h07b;
assign code[9'h14d] = 9'h07b;
assign code[9'h14e] = 9'h07b;
assign code[9'h14f] = 9'h07b;
assign code[9'h150] = 9'h07b;
assign code[9'h151] = 9'h07b;
assign code[9'h152] = 9'h07b;
assign code[9'h153] = 9'h07b;
assign code[9'h154] = 9'h07b;
assign code[9'h155] = 9'h07b;
assign code[9'h156] = 9'h07b;
assign code[9'h157] = 9'h07b;
assign code[9'h158] = 9'h07b;
assign code[9'h159] = 9'h07b;
assign code[9'h15a] = 9'h119;  //KP ENTER
assign code[9'h15b] = 9'h07b;
assign code[9'h15c] = 9'h07b;
assign code[9'h15d] = 9'h07b;
assign code[9'h15e] = 9'h07b;
assign code[9'h15f] = 9'h07b;
assign code[9'h160] = 9'h07b;
assign code[9'h161] = 9'h07b;
assign code[9'h162] = 9'h07b;
assign code[9'h163] = 9'h07b;
assign code[9'h164] = 9'h07b;
assign code[9'h165] = 9'h07b;
assign code[9'h166] = 9'h07b;
assign code[9'h167] = 9'h07b;
assign code[9'h168] = 9'h07b;
assign code[9'h169] = 9'h07b;  //END
assign code[9'h16a] = 9'h07b;
assign code[9'h16b] = 9'h10d;  //ARROW LEFT
assign code[9'h16c] = 9'h07b;  //HOME
assign code[9'h16d] = 9'h07b;
assign code[9'h16e] = 9'h07b;
assign code[9'h16f] = 9'h07b;
assign code[9'h170] = 9'h07b;  //INSERT = HELP
assign code[9'h171] = 9'h10f;  //DELETE (KP clear?)
assign code[9'h172] = 9'h111;  //ARROW DOWN
assign code[9'h173] = 9'h07b;
assign code[9'h174] = 9'h105;  //ARROW RIGHT
assign code[9'h175] = 9'h11b;  //ARROW UP
assign code[9'h176] = 9'h07b;
assign code[9'h177] = 9'h07b;
assign code[9'h178] = 9'h07b;
assign code[9'h179] = 9'h07b;
assign code[9'h17a] = 9'h07b;  //PGDN <OSD>
assign code[9'h17b] = 9'h07b;
assign code[9'h17c] = 9'h07b;  //PRTSCR <OSD>
assign code[9'h17d] = 9'h07b;  //PGUP <OSD>
assign code[9'h17e] = 9'h07b;  //ctrl+break
assign code[9'h17f] = 9'h07b;
assign code[9'h180] = 9'h07b;
assign code[9'h181] = 9'h07b;
assign code[9'h182] = 9'h07b;
assign code[9'h183] = 9'h07b;
assign code[9'h184] = 9'h07b;
assign code[9'h185] = 9'h07b;
assign code[9'h186] = 9'h07b;
assign code[9'h187] = 9'h07b;
assign code[9'h188] = 9'h07b;
assign code[9'h189] = 9'h07b;
assign code[9'h18a] = 9'h07b;
assign code[9'h18b] = 9'h07b;
assign code[9'h18c] = 9'h07b;
assign code[9'h18d] = 9'h07b;
assign code[9'h18e] = 9'h07b;
assign code[9'h18f] = 9'h07b;
assign code[9'h190] = 9'h07b;
assign code[9'h191] = 9'h07b;
assign code[9'h192] = 9'h07b;
assign code[9'h193] = 9'h07b;
assign code[9'h194] = 9'h07b;
assign code[9'h195] = 9'h07b;
assign code[9'h196] = 9'h07b;
assign code[9'h197] = 9'h07b;
assign code[9'h198] = 9'h07b;
assign code[9'h199] = 9'h07b;
assign code[9'h19a] = 9'h07b;
assign code[9'h19b] = 9'h07b;
assign code[9'h19c] = 9'h07b;
assign code[9'h19d] = 9'h07b;
assign code[9'h19e] = 9'h07b;
assign code[9'h19f] = 9'h07b;
assign code[9'h1a0] = 9'h07b;
assign code[9'h1a1] = 9'h07b;
assign code[9'h1a2] = 9'h07b;
assign code[9'h1a3] = 9'h07b;
assign code[9'h1a4] = 9'h07b;
assign code[9'h1a5] = 9'h07b;
assign code[9'h1a6] = 9'h07b;
assign code[9'h1a7] = 9'h07b;
assign code[9'h1a8] = 9'h07b;
assign code[9'h1a9] = 9'h07b;
assign code[9'h1aa] = 9'h07b;
assign code[9'h1ab] = 9'h07b;
assign code[9'h1ac] = 9'h07b;
assign code[9'h1ad] = 9'h07b;
assign code[9'h1ae] = 9'h07b;
assign code[9'h1af] = 9'h07b;
assign code[9'h1b0] = 9'h07b;
assign code[9'h1b1] = 9'h07b;
assign code[9'h1b2] = 9'h07b;
assign code[9'h1b3] = 9'h07b;
assign code[9'h1b4] = 9'h07b;
assign code[9'h1b5] = 9'h07b;
assign code[9'h1b6] = 9'h07b;
assign code[9'h1b7] = 9'h07b;
assign code[9'h1b8] = 9'h07b;
assign code[9'h1b9] = 9'h07b;
assign code[9'h1ba] = 9'h07b;
assign code[9'h1bb] = 9'h07b;
assign code[9'h1bc] = 9'h07b;
assign code[9'h1bd] = 9'h07b;
assign code[9'h1be] = 9'h07b;
assign code[9'h1bf] = 9'h07b;
assign code[9'h1c0] = 9'h07b;
assign code[9'h1c1] = 9'h07b;
assign code[9'h1c2] = 9'h07b;
assign code[9'h1c3] = 9'h07b;
assign code[9'h1c4] = 9'h07b;
assign code[9'h1c5] = 9'h07b;
assign code[9'h1c6] = 9'h07b;
assign code[9'h1c7] = 9'h07b;
assign code[9'h1c8] = 9'h07b;
assign code[9'h1c9] = 9'h07b;
assign code[9'h1ca] = 9'h07b;
assign code[9'h1cb] = 9'h07b;
assign code[9'h1cc] = 9'h07b;
assign code[9'h1cd] = 9'h07b;
assign code[9'h1ce] = 9'h07b;
assign code[9'h1cf] = 9'h07b;
assign code[9'h1d0] = 9'h07b;
assign code[9'h1d1] = 9'h07b;
assign code[9'h1d2] = 9'h07b;
assign code[9'h1d3] = 9'h07b;
assign code[9'h1d4] = 9'h07b;
assign code[9'h1d5] = 9'h07b;
assign code[9'h1d6] = 9'h07b;
assign code[9'h1d7] = 9'h07b;
assign code[9'h1d8] = 9'h07b;
assign code[9'h1d9] = 9'h07b;
assign code[9'h1da] = 9'h07b;
assign code[9'h1db] = 9'h07b;
assign code[9'h1dc] = 9'h07b;
assign code[9'h1dd] = 9'h07b;
assign code[9'h1de] = 9'h07b;
assign code[9'h1df] = 9'h07b;
assign code[9'h1e0] = 9'h07b;  //ps2 extended key(duplicate, see $e0)
assign code[9'h1e1] = 9'h07b;
assign code[9'h1e2] = 9'h07b;
assign code[9'h1e3] = 9'h07b;
assign code[9'h1e4] = 9'h07b;
assign code[9'h1e5] = 9'h07b;
assign code[9'h1e6] = 9'h07b;
assign code[9'h1e7] = 9'h07b;
assign code[9'h1e8] = 9'h07b;
assign code[9'h1e9] = 9'h07b;
assign code[9'h1ea] = 9'h07b;
assign code[9'h1eb] = 9'h07b;
assign code[9'h1ec] = 9'h07b;
assign code[9'h1ed] = 9'h07b;
assign code[9'h1ee] = 9'h07b;
assign code[9'h1ef] = 9'h07b;
assign code[9'h1f0] = 9'h07b;  //ps2 release code(duplicate, see $f0)
assign code[9'h1f1] = 9'h07b;
assign code[9'h1f2] = 9'h07b;
assign code[9'h1f3] = 9'h07b;
assign code[9'h1f4] = 9'h07b;
assign code[9'h1f5] = 9'h07b;
assign code[9'h1f6] = 9'h07b;
assign code[9'h1f7] = 9'h07b;
assign code[9'h1f8] = 9'h07b;
assign code[9'h1f9] = 9'h07b;
assign code[9'h1fa] = 9'h07b;  //ps2 ack code(duplicate see $fa)
assign code[9'h1fb] = 9'h07b;
assign code[9'h1fc] = 9'h07b;
assign code[9'h1fd] = 9'h07b;
assign code[9'h1fe] = 9'h07b;
assign code[9'h1ff] = 9'h07b;

endmodule
