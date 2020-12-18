`default_nettype none
/* Synchronous 8-bit replica of 3.5 inch floppy disk drive.

	Differences from the true floppy interace at the Mac's DB-19 port:
	True interface has a writeReq control line, only 1-bit readData and writeData, and no clk.
	True interface does not have newByteReady signal. Instead the IWM must watch the data in bit and synchronize with it to
	   determine the timing and framing of bytes.
	
*/

/* Disk register (read):	
	    State-control lines       Register
  CA2    CA1    CA0    SEL    addressed    Information in register

  0      0      0      0      DIRTN        Head step direction (0=toward track 79, 1=toward track 0)
  0      0      0      1      CSTIN        Disk in place (0=disk is inserted)
  0      0      1      0      STEP         Drive head stepping (setting to 0 performs a step, returns to 1 when step is complete)
  0      0      1      1      WRTPRT       Disk locked (0=locked)
  0      1      0      0      MOTORON      Drive motor running (0=on, 1=off)
  0      1      0      1      TKO          Head at track 0 (0=at track 0)
  0		1		 1		  0		SWITCHED   	 Disk switched (1=yes?)
  0      1      1      1      TACH         Tachometer (produces 60 pulses for each rotation of the drive motor)
  1      0      0      0      RDDATA0      Read data, lower head, side 0
  1      0      0      1      RDDATA1      Read data, upper head, side 1 
  1      0      1      0      SUPERDR      Drive is a Superdrive (0=no, 1=yes)
  1      1      0      0      SIDES        Single- or double-sided drive (0=single side, 1=double side)
  1      1      0      1      READY        0 = yes
  1      1      1      0      INSTALLED	 0 = yes
  1      1      1      1      DRVIN        400K/800K: Drive installed (0=drive is present), Superdrive: Inserted disk capacity (0=HD, 1=DD)
	
	Disk registers (write):
    Control lines      Register
  CA1    CA0    SEL    addressed    Register function

  0      0      0      DIRTN        Set stepping direction (0=toward track 79, 1=toward track 0)
  0      0      1      SWITCHED		Reset disk switched flag (writing 1 sets switch flag to 0)
  0      1      0      STEP         Step the drive head one track (setting to 0 performs a step, returns to 1 when step is complete)
  1      0      0      MOTORON      Turn on/off drive motor (0=on, 1=off)
  1      1      0      EJECT        Eject the disk (writing 1 ejects the disk)
	
*/

`define DRIVE_REG_DIRTN		0  /* R/W: step direction (0=toward track 79, 1=toward track 0) */
`define DRIVE_REG_CSTIN		1  /* R: disk in place (1 = no disk) */
	                           /* W: ?? reset disk switch flag ? */
`define DRIVE_REG_STEP		2  /* R: drive head is stepping (1 = complete) */
	                           /* W: 0 = step drive head */
`define DRIVE_REG_WRTPRT	3  /* R: 0 = disk is write-protected */
`define DRIVE_REG_MOTORON	4  /* R/W: 0 = motor on */
`define DRIVE_REG_TK0		5  /* R: 0 = head at track 0 */
`define DRIVE_REG_EJECT		6  /* R: disk switched (1=yes?)*/
	                           /* W: 1 = eject the disk */
`define DRIVE_REG_TACH		7  /* R: tach-o-meter */
`define DRIVE_REG_RDDATA0	8  /* R: activate lower head: side 0 */
`define DRIVE_REG_RDDATA1	9  /* R: activate upper head: side 1 */
`define DRIVE_REG_SUPERDR	10 /* R: drive is a superdrive (0=no, 1=yes) */
`define DRIVE_REG_SIDES		12 /* R: number of sides (0=single, 1=dbl) */
`define DRIVE_REG_READY		13 /* R: drive ready (head loaded) (0=ready) */
`define DRIVE_REG_INSTALLED	14 /* R: drive present (0 = yes ??) */
`define DRIVE_REG_DRVIN		15 /* R: 400K/800k: drive present (0=yes, 1=no), Superdrive: disk capacity (0=HD, 1=DD) */

module floppy(
	input clk,
	input _reset,
	input cep,
	input cen,
	input ca0,				// PH0
	input ca1,				// PH1
	input ca2,				// PH2
	input SEL, 				// HDSEL from VIA
	input lstrb,				// aka PH3
	input _enable, 			
	input [7:0] writeData,		
	output [7:0] readData,
	
	input useDiskImage,
	input advanceDriveHead,  		// prevents overrun when debugging, does not exist on a real Mac!
	output reg newByteReady,
	input insertDisk,
	output diskInDrive,
	
	output [21:0] extraRomReadAddr,
	input extraRomReadAck,
	input [7:0] extraRomReadData,
	output [6:0] track,
	output side,
	input stepping
);

	reg [15:0] driveRegs;
	reg [6:0] driveTrack;
	reg driveSide;
	wire [7:0] diskDataIn = extraRomReadData; 	// incoming byte from the floppy disk
	
	assign track = driveTrack;
	assign side = driveSide;

	// read drive registers
	wire [15:0] driveRegsAsRead = {
		1'b0, // DRVIN = yes
		1'b0, // INSTALLED = yes
		1'b0, // READY = yes
		1'b1, // SIDES = double-sided drive
		1'b0, // UNUSED
		1'b0, // SUPERDR
		1'b0, // RDDATA1
		1'b0, // RDDATA0
		driveRegs[`DRIVE_REG_TACH], // TACH: 60 pules for each rotation of the drive motor
		1'b0, // disk switched?
		~(driveTrack == 7'h00), // TK0: track 0 indicator
		driveRegs[`DRIVE_REG_MOTORON], // motor on
		1'b0, // WRTPRT = locked
		stepping, // STEP, 1 = complete
		driveRegs[`DRIVE_REG_CSTIN], // disk in drive
		driveRegs[`DRIVE_REG_DIRTN] // step direction
	};
	
	// TODO: auto-detect doubleSidedDisk from image file size
	wire doubleSidedDisk = 1'b1;
	
	// number of bytes in one side of the current track 
	reg [15:0] diskImageTrackSideLen;
	always @(*) begin
		case (driveTrack[6:4]) 
			3'b000:
				diskImageTrackSideLen = 12 * 1024;
			3'b001:
				diskImageTrackSideLen = 11 * 1024;	
			3'b010:
				diskImageTrackSideLen = 10 * 1024;	
			3'b011:
				diskImageTrackSideLen = 9 * 1024;	
			3'b100:
				diskImageTrackSideLen = 8 * 1024;	
			default:
				diskImageTrackSideLen = 8 * 1024;	
		endcase
	end
	wire [15:0] diskImageTrackLen = doubleSidedDisk ? {diskImageTrackSideLen[14:0], 1'b0 } : diskImageTrackSideLen;
	// number of bytes in one side of the track before the current track (used for stepping backwards)
	wire [6:0] driveTrackMinus1 = driveTrack - 1'b1; // can't step backward from track 0, so underflow doesn't matter
	reg [15:0] diskImageTrackMinus1SideLen;
	always @(*) begin
		case (driveTrackMinus1[6:4]) 
			3'b000: diskImageTrackMinus1SideLen = 12 * 1024;
			3'b001: diskImageTrackMinus1SideLen = 11 * 1024;	
			3'b010: diskImageTrackMinus1SideLen = 10 * 1024;	
			3'b011: diskImageTrackMinus1SideLen = 9 * 1024;	
			3'b100: diskImageTrackMinus1SideLen = 8 * 1024;	
			default: diskImageTrackMinus1SideLen = 8 * 1024;	
		endcase
	end
	wire [15:0] diskImageTrackMinus1Len = doubleSidedDisk ? {diskImageTrackMinus1SideLen[14:0], 1'b0 } : diskImageTrackMinus1SideLen;
	
	
	// offset from the start of the disk image to the start of the current track
	reg [21:0] diskImageTrackBase;

	// bytes offset in the current side of the current track, must be less than diskImageTrackSideLen
	reg [15:0] diskImageHeadOffset;
	
	assign extraRomReadAddr = 
		((driveSide && doubleSidedDisk) ? diskImageTrackSideLen : 0) +
		diskImageHeadOffset;

	wire [3:0] driveReadAddr = {ca2,ca1,ca0,SEL};
        reg addressSet;	
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			diskImageHeadOffset <= 1'b0;
			driveSide <= 0;
                        newByteReady <= 1'b0;
			addressSet <= 1;
		end else begin			
			addressSet <= 0;
			if (advanceDriveHead) begin
				addressSet <= 1'b1;
				
				if (diskImageHeadOffset + 1'b1 >= diskImageTrackSideLen) diskImageHeadOffset <= 0;
				else diskImageHeadOffset <= diskImageHeadOffset + 1'b1;
			end
		
			newByteReady <= addressSet;	
			// switch drive sides if DRIVE_REG_RDDATA0 or DRIVE_REG_RDDATA1 are read
			// TODO: we don't know if this is a true read, since we don't know if IWM is selected or 
			// could be bad if we use this test to flush a cache of encoded disk data
			if (driveReadAddr == `DRIVE_REG_RDDATA0 && lstrb == 1'b0) driveSide <= 0;
			if (driveReadAddr == `DRIVE_REG_RDDATA1 && lstrb == 1'b0) driveSide <= 1;	
		end
	end
	
	reg lstrbPrev;
	always @(posedge clk) lstrbPrev <= lstrb;
	wire lstrbEdge = lstrb == 1'b0 && lstrbPrev == 1'b1;
	
	assign readData = _enable == 1'b1 ? 8'hZZ :
							(driveReadAddr == `DRIVE_REG_RDDATA0 || driveReadAddr == `DRIVE_REG_RDDATA1) ? diskDataIn :
							{ driveRegsAsRead[driveReadAddr], 7'h00 };
		
	// write drive registers
	wire [2:0] driveWriteAddr = {ca1,ca0,SEL};
	
	// DRIVE_REG_DIRTN		0  /* R/W: step direction (0=toward track 79, 1=toward track 0) */
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) driveRegs[`DRIVE_REG_DIRTN] <= 1'b0;
		else if (_enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_DIRTN) driveRegs[`DRIVE_REG_DIRTN] <= ca2;
	end


	// DRIVE_REG_CSTIN		1  /* R: disk in place (1 = no disk) */
					   /* W: ?? reset disk switch flag ? */
	// disk in drive indicators
	reg [23:0] ejectIndicatorTimer;
	assign diskInDrive = ~driveRegs[`DRIVE_REG_CSTIN] | ejectIndicatorTimer[20];
	
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			driveRegs[`DRIVE_REG_CSTIN] <= 1'b1;
		end else if (_enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_EJECT && ca2 == 1'b1) begin
			// eject the disk
			driveRegs[`DRIVE_REG_CSTIN] <= 1'b1;
			ejectIndicatorTimer <= 24'hFFFFFF;
		end else if (insertDisk) begin
			// insert a disk
			driveRegs[`DRIVE_REG_CSTIN] <= 1'b0;
		end else begin
			if (ejectIndicatorTimer != 0)
				ejectIndicatorTimer <= ejectIndicatorTimer - 1'b1;
		end
	end									
									
	//`define DRIVE_REG_STEP		2  /* R: drive head stepping (1 = complete) */
						   /* W: 0 = step drive head */
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin	
			driveTrack <= 0; 
			diskImageTrackBase <= 0;
		end else if (_enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_STEP && ca2 == 1'b0) begin
			if (driveRegs[`DRIVE_REG_DIRTN] == 1'b0 && driveTrack != 7'h4F) begin
				driveTrack <= driveTrack + 1'b1;
				diskImageTrackBase <= diskImageTrackBase + diskImageTrackLen;
			end
			if (driveRegs[`DRIVE_REG_DIRTN] == 1'b1 && driveTrack != 0) begin
				driveTrack <= driveTrack - 1'b1;
				diskImageTrackBase <= diskImageTrackBase - diskImageTrackMinus1Len;
			end
		end
	end
	
	// DRIVE_REG_MOTORON	4  /* R/W: 0 = motor on */
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			driveRegs[`DRIVE_REG_MOTORON] <= 1'b1;
		end else if (_enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_MOTORON) begin
			driveRegs[`DRIVE_REG_MOTORON] <= ca2;
		end
	end

	// DRIVE_REG_TACH  7  Tachometer (produces 60 pulses for each rotation of the drive motor)
	/* Data from MESS, sonydriv.c:
	   Tracks	RPM   Timing Value
	   00-15:   500   timing value $117B (acceptable range {1135-11E9})
	   16-31:   550   timing value $???? (acceptable range {12C6-138A})
	   32-47:   600   timing value $???? (acceptable range {14A7-157F})
	   48-63:   675   timing value $???? (acceptable range {16F2-17E2})
	   64-79:   750   timing value $???? (acceptable range {19D0-1ADE})
		
		Experimentally determined toggle rates for Plus Too with 8.125 MHz CPU clock:
		TACH Half Period Clocks		Resulting Timing Value
					9996					$117B (4475)
					9122  				$1328 (4904)
					8292  				$1513 (5395)
					7463  				$176A (5994)
					6634					$1A56 (6742)
	*/
	
	reg [13:0] driveTachTimer; 
	reg [13:0] driveTachPeriod;
	
	always @(*) begin
		case (driveTrack[6:4])
			0: // tracks 0-15
				driveTachPeriod = 9996;
			1: // tracks 16-31
				driveTachPeriod = 9122;
			2: // tracks 32-47
				driveTachPeriod = 8292;
			3: // tracks 48-63
				driveTachPeriod = 7463;
			default: // tracks 64-79
				driveTachPeriod = 6634;	
		endcase
	end
	
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			driveRegs[`DRIVE_REG_TACH] <= 1'b0;
			driveTachTimer <= 0;
		end else if (cep) begin
			if (driveTachTimer == driveTachPeriod) begin
				driveTachTimer <= 0;
				driveRegs[`DRIVE_REG_TACH] <= ~driveRegs[`DRIVE_REG_TACH];
			end else begin
				driveTachTimer <= driveTachTimer + 1'b1;
			end
		end
	end

endmodule
