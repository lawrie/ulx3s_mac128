# ulx3s_mac128

## Introduction

Despite the name of this repository, it is currently implements a Macintosh Plus computer from 1986, on a Ulx3s ECP5 FPGA board.

There are very few differences in the hardware, between the Mac 128K, 512K and that Mac Plus. The Mac Plus has 4MB of RAM, double-sided 800KB floppy disk drives and a 128KB ROM, the Mac 128K has 128KB of RAM, single-sided 400KB floppy disk drives and 64KB of ROM. The addresses of the screen buffer and the sound buffer differ for the different variants of the machines and hence, are parameters to the top-level Verilog module.

This implementation is written entirely in Verilog and built with the open source tools: yosys, nextpnr and project trellis.

Some of the source comes from the [PlusToo](https://www.bigmessowires.com/2012/12/15/plus-too-files/) Verilog implementation and some from the [Mist](https://github.com/mist-devel/mist-board/tree/master/cores/plus_too) and [Mister](https://github.com/MiSTer-devel/MacPlus_MiSTer) versions that were derived from that, but a lot is new.

One difference from those versions is that the [fx68k](https://github.com/ijor/fx68k) 68000 CPU implementation is used. This was converted from System Verilog and has been used in other Ulx3s 68k projects, such as the Sinclair QL.

The CPU uses a 25MHz clock, but this is divided into phase 1 and phase 2 clock enablers, so the CPU runs at 12.5MHz. This is faster than the 7.8336 MHz that the real hardware ran at, or the 8.25 MHz that the PlusToo runs at.

The SDRAM and HDMI video uses a 125 MHz clock. The SDRAM implementation is by Paul Ruiz ands was written specifically for the fx68k cpu running on the Ulx3s.

A difference between this implementation and the others is that SDRAM access is not interleaved with video, sound and motor driving, as it is on the real hardware. Instead dual-ported BRAM is used for the video and sound buffers, so that these buffers can be accessed while the CPU is still running.

The top level Verilog module, the video circuit and the BRAM buffer implementations, are all new for the this version. Several modules used by PlusToo and the Mist/Mister variants have been dropped and the VIA and SCC chip implementation are cut-down versions in the top-level module.

The mouse and keyboard code comes mainly from the PlusToo and Mist versions, and the floppy disk implementation is similar to the Plustoo implementation and uses versions of iwm.v and floppy.v from that.

The floppy disk imlementation differs quite a bit from the PlusToo and other variants, in that it uses a BRAM track buffer rather than holding a whole floppy disk image in ROM or SDRAM. When a new track is required, it is requested from the ESP32. This requires halting the CPU, as sending the data from the ESP32 takes slighly longer than stepping to a new track took on the real hardware. Another difference in the floppy disk implementation is that there is not attempt to spin the disks at the speed of the real hardware, which was 128 clock cycles per byte. Instead delivery of bytes is synchronized with reads from the ROM.

Both the internal and external floppy disk drives are supported, by the SCSI hard disk is not supported.

Sound is supported.

## Bugs

Currently there is a problem with the floppy disk reading that sometimes causes a disk error to be reported. This goes away when the disk is ejected and re-inserted. It seems to occur when the system disk is initially inserted into the external drive.

The CPU halting causes the mouse to stop working when the floppy disk is accessed. This happens on the real hardware but not as often.

The keyboard timing is wrong which means that you have to hold a key down for a while until is is recognized and then it auto-repeats and does not stop until you press a key again. However, a lot od Mac software uses only the mouse and does not require the keyboard.

## Installation

You need recent versions of yosys, nextpnr, project trellis and fujprog.

After cloning the repository, the bitstream is built by:

```
cd mac128/ulx3s
make prog
```

## Running

When you program the bitstream, you should see the flashing floppy disk icon with a "?" meaning that a floppy disk is required.

To insert a floppy disk, you need micropython on the ESP32, and you should upload osd.py and dsk2mac.py from the esp32/osd directory, and do "import osd", but only after the bitstream is running on the fpga.

You can then start the OSD by pressing all 4 direction buttons at the same time. 

Disk images should normally be held on an SD card in .dsk format. 800KB disk images will be exactly 800KB, and single-side 400KB ones, exactly 400KB. These are converted to the encoded 6-and-2 format expected by the ROM by the ESP32.

Exapanded .mac versions that are twice as big are also supported. These are pre-encoded.

When you start the OSD, you should navigate to the required image using the up, down, left and right direction buttons. These are uually under /sd on the SD card, but an image in ESP32 flash memory is also supported.

Once a disk image is selected, the disk is inserted by press button 6 to use the internal drive, or button 1 to use the external drive.

You should never insert a disk into a drive that is already in use as this will cause system errors. You should eject a disk first and wait until  the ejection is complete, which takes a  few seconds. Leds 0 and 1 indicate if the internal and external drives are in use.

When you have inserted a system floppy, the Finder should start. You will see the Macintosh start-up message first. It takes up to about a minute to load a system disk, but some load in about 15 seconds. Once you have a system disk loaded, you should be able to eject disks and insert disks into the internal and external drives.

The Disk605.dsk system disk image is available in the roms directory.

There are many disk images in .dsk format on the Internet, including [Mac Plus games]( https://www.macintoshrepository.org/24802-mac-plus-floppy-with-games) and [Space Invaders]( https://www.macintoshrepository.org/4826-space-invaders). The Space Invaders disk is a 400KB system disk, so contains the Finder and loads fast.

Many games are playable with just the mouse.

The keyboard requires Goran Mahovlic's USB Pmod and uses US3, and a PS/2 compatible keyboard.

The mouse plugs into US2, via an OTG adapter, and needs a PS/2 compatible USB mouse, or a PS/2 mouse and a suitable adapter (see the [ulx3s manual](https://github.com/emard/ulx3s/blob/master/doc/MANUAL.md)).
