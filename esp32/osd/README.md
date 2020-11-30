# OSD SPI loader

Copy also esp32ecp5 *.py files to root of esp32 flash fs,
use ftp to transfer files. To start OSD just do this

    import osd

It will install IRQ handler for SPI and buttons.
Prompt will appear.

Rename m68k compiled files to file.mx1 and use OSD to load
Press all 4 up/down/left/right direction buttons at the same time
and SD card browser will pop up in OSD window.

to inspect memory content:

    >>> osd.poke(1000,"abcd")
    >>> osd.peek(1000,4)
    bytearray(b'abcd')

    