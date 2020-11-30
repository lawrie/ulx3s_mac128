# micropython ESP32
# OSD SPI loader for retro computing

# AUTHOR=EMARD
# LICENSE=BSD

# this code is SPI master to FPGA SPI slave
# FPGA sends pulse to GPIO after BTN state is changed.
# on GPIO pin interrupt from FPGA:
# btn_state = SPI_read
# SPI_write(buffer)
# FPGA SPI slave will accept image and start it

from machine import SPI, Pin, SDCard, Timer
from micropython import const, alloc_emergency_exception_buf
from uctypes import addressof
from struct import unpack
from time import sleep_ms
import os
import gc
import ecp5

class osd:
  def __init__(self):
    self.screen_x = const(64)
    self.screen_y = const(20)
    self.cwd = "/"
    self.init_fb()
    self.exp_names = " KMGTE"
    self.mark = bytearray([32,16,42]) # space, right triangle, asterisk
    self.diskfile=False
    self.data_buf=bytearray(554)
    self.mdv_byte=bytearray(1)
    self.mdv_phase=bytearray([1])
    self.read_dir()
    self.spi_read_irq = bytearray([1,0xF1,0,0,0,0,0])
    self.spi_read_btn = bytearray([1,0xFB,0,0,0,0,0])
    self.spi_read_blktyp = bytearray([1,0xD0,0,0,0,0,0])
    self.spi_result = bytearray(7)
    self.spi_enable_osd = bytearray([0,0xFE,0,0,0,1])
    self.spi_write_osd = bytearray([0,0xFD,0,0,0])
    self.spi_send_mdv_bram = bytearray([0,0xD1,0,0,0])
    self.spi_channel = const(2)
    self.spi_freq = const(3000000)
    self.init_pinout_sd()
    self.init_spi()
    alloc_emergency_exception_buf(100)
    self.enable = bytearray(1)
    self.timer = Timer(3)
    self.irq_handler(0)
    self.irq_handler_ref = self.irq_handler # allocation happens here
    self.spi_request = Pin(0, Pin.IN, Pin.PULL_UP)
    self.spi_request.irq(trigger=Pin.IRQ_FALLING, handler=self.irq_handler_ref)

  def init_spi(self):
    self.spi=SPI(self.spi_channel, baudrate=self.spi_freq, polarity=0, phase=0, bits=8, firstbit=SPI.MSB, sck=Pin(self.gpio_sck), mosi=Pin(self.gpio_mosi), miso=Pin(self.gpio_miso))
    self.cs=Pin(self.gpio_cs,Pin.OUT)
    self.cs.off()
    self.led=Pin(self.gpio_led,Pin.OUT)
    self.led.off()

# init file browser
  def init_fb(self):
    self.fb_topitem = 0
    self.fb_cursor = 0
    self.fb_selected = -1

  @micropython.viper
  def init_pinout_sd(self):
    self.gpio_cs   = const(17)
    self.gpio_sck  = const(16)
    self.gpio_mosi = const(4)
    self.gpio_miso = const(12)
    self.gpio_led  = const(5)

  @micropython.viper
  def irq_handler(self, pin):
    p8result = ptr8(addressof(self.spi_result))
    self.cs.on()
    self.spi.write_readinto(self.spi_read_irq, self.spi_result)
    self.cs.off()
    btn_irq = p8result[6]
    if btn_irq&1: # microdrive 1 request
      #self.cs.on()
      #self.spi.write_readinto(self.spi_read_blktyp,self.spi_result)
      #self.cs.off()
      #blktyp=p8result[6]
      if self.diskfile:
        self.mdv_read()
    if btn_irq&0x80: # btn event IRQ flag
      self.cs.on()
      self.spi.write_readinto(self.spi_read_btn, self.spi_result)
      self.cs.off()
      btn = p8result[6]
      p8enable = ptr8(addressof(self.enable))
      if p8enable[0]&2: # wait to release all BTNs
        if btn==1:
          p8enable[0]&=1 # clear bit that waits for all BTNs released
      else: # all BTNs released
        if (btn&0x78)==0x78: # all cursor BTNs pressed at the same time
          self.show_dir() # refresh directory
          p8enable[0]=(p8enable[0]^1)|2;
          self.osd_enable(p8enable[0]&1)
        if p8enable[0]==1:
          if btn==9: # btn3 cursor up
            self.start_autorepeat(-1)
          if btn==17: # btn4 cursor down
            self.start_autorepeat(1)
          if btn==1:
            self.timer.deinit() # stop autorepeat
          if btn==33: # btn5 cursor left
            self.updir()
          if btn==65: # btn6 cursor right
            self.select_entry()

  def start_autorepeat(self, i:int):
    self.autorepeat_direction=i
    self.move_dir_cursor(i)
    self.timer_slow=1
    self.timer.init(mode=Timer.PERIODIC, period=500, callback=self.autorepeat)

  def autorepeat(self, timer):
    if self.timer_slow:
      self.timer_slow=0
      self.timer.init(mode=Timer.PERIODIC, period=30, callback=self.autorepeat)
    self.move_dir_cursor(self.autorepeat_direction)
    self.irq_handler(0) # catch stale IRQ

  def select_entry(self):
    if self.direntries[self.fb_cursor][1]: # is it directory
      oldselected = self.fb_selected - self.fb_topitem
      self.fb_selected = self.fb_cursor
      try:
        self.cwd = self.fullpath(self.direntries[self.fb_cursor][0])
      except:
        self.fb_selected = -1
      self.show_dir_line(oldselected)
      self.show_dir_line(self.fb_cursor - self.fb_topitem)
      self.init_fb()
      self.read_dir()
      self.show_dir()
    else:
      self.change_file()

  def updir(self):
    if len(self.cwd) < 2:
      self.cwd = "/"
    else:
      s = self.cwd.split("/")[:-1]
      self.cwd = ""
      for name in s:
        if len(name) > 0:
          self.cwd += "/"+name
    self.init_fb()
    self.read_dir()
    self.show_dir()

  def fullpath(self,fname):
    if self.cwd.endswith("/"):
      return self.cwd+fname
    else:
      return self.cwd+"/"+fname

  def change_file(self):
    oldselected = self.fb_selected - self.fb_topitem
    self.fb_selected = self.fb_cursor
    try:
      filename = self.fullpath(self.direntries[self.fb_cursor][0])
    except:
      filename = False
      self.fb_selected = -1
    self.show_dir_line(oldselected)
    self.show_dir_line(self.fb_cursor - self.fb_topitem)
    if filename:
      if filename.endswith(".mdv") or filename.endswith(".MDV"):
        self.diskfile = open(filename,"rb")
        self.mdv_refill_buf()
        self.enable[0]=0
        self.osd_enable(0)
      if filename.endswith(".bit"):
        self.spi_request.irq(handler=None)
        self.timer.deinit()
        self.enable[0]=0
        self.osd_enable(0)
        self.spi.deinit()
        tap=ecp5.ecp5()
        tap.prog_stream(open(filename,"rb"),blocksize=1024)
        if filename.endswith("_sd.bit"):
          os.umount("/sd")
          for i in bytearray([2,4,12,13,14,15]):
            p=Pin(i,Pin.IN)
            a=p.value()
            del p,a
        result=tap.prog_close()
        del tap
        gc.collect()
        #os.mount(SDCard(slot=3),"/sd") # BUG, won't work
        self.init_spi() # because of ecp5.prog() spi.deinit()
        self.spi_request.irq(trigger=Pin.IRQ_FALLING, handler=self.irq_handler_ref)
        self.irq_handler(0) # handle stuck IRQ
      if filename.endswith(".nes") \
      or filename.endswith(".snes") \
      or filename.endswith(".smc") \
      or filename.endswith(".sfc"):
        import ld_nes
        s=ld_nes.ld_nes(self.spi,self.cs)
        s.ctrl(1)
        s.ctrl(0)
        s.load_stream(open(filename,"rb"))
        del s
        gc.collect()
        self.enable[0]=0
        self.osd_enable(0)
      if filename.startswith("/sd/ti99_4a/") and filename.endswith(".bin"):
        import ld_ti99_4a
        s=ld_ti99_4a.ld_ti99_4a(self.spi,self.cs)
        s.load_rom_auto(open(filename,"rb"),filename)
        del s
        gc.collect()
        self.enable[0]=0
        self.osd_enable(0)
      if (filename.startswith("/sd/msx") and filename.endswith(".rom")) \
      or filename.endswith(".mx1"):
        import ld_msx
        s=ld_msx.ld_msx(self.spi,self.cs)
        s.load_msx_rom(open(filename,"rb"))
        del s
        gc.collect()
        self.enable[0]=0
        self.osd_enable(0)
      if filename.endswith(".z80"):
        self.enable[0]=0
        self.osd_enable(0)
        import ld_zxspectrum
        s=ld_zxspectrum.ld_zxspectrum(self.spi,self.cs)
        s.loadz80(filename)
        del s
        gc.collect()
      if filename.endswith(".ora") or filename.endswith(".orao"):
        self.enable[0]=0
        self.osd_enable(0)
        import ld_orao
        s=ld_orao.ld_orao(self.spi,self.cs)
        s.loadorao(filename)
        del s
        gc.collect()
      if filename.endswith(".vsf"):
        self.enable[0]=0
        self.osd_enable(0)
        import ld_vic20
        s=ld_vic20.ld_vic20(self.spi,self.cs)
        s.loadvsf(filename)
        del s
        gc.collect()
      if filename.endswith(".prg"):
        self.enable[0]=0
        self.osd_enable(0)
        import ld_vic20
        s=ld_vic20.ld_vic20(self.spi,self.cs)
        s.loadprg(filename)
        del s
        gc.collect()
      if filename.endswith(".cas"):
        self.enable[0]=0
        self.osd_enable(0)
        import ld_trs80
        s=ld_trs80.ld_trs80(self.spi,self.cs)
        s.loadcas(filename)
        del s
        gc.collect()
      if filename.endswith(".cmd"):
        self.enable[0]=0
        self.osd_enable(0)
        import ld_trs80
        s=ld_trs80.ld_trs80(self.spi,self.cs)
        s.loadcmd(filename)
        del s
        gc.collect()

  @micropython.viper
  def osd_enable(self, en:int):
    pena = ptr8(addressof(self.spi_enable_osd))
    pena[5] = en&1
    self.cs.on()
    self.spi.write(self.spi_enable_osd)
    self.cs.off()

  @micropython.viper
  def osd_print(self, x:int, y:int, i:int, text):
    p8msg=ptr8(addressof(self.spi_write_osd))
    a=0xF000+(x&63)+((y&31)<<6)
    p8msg[2]=i
    p8msg[3]=a>>8
    p8msg[4]=a
    self.cs.on()
    self.spi.write(self.spi_write_osd)
    self.spi.write(text)
    self.cs.off()

  @micropython.viper
  def osd_cls(self):
    p8msg=ptr8(addressof(self.spi_write_osd))
    p8msg[3]=0xF0
    p8msg[4]=0
    self.cs.on()
    self.spi.write(self.spi_write_osd)
    self.spi.read(1280,32)
    self.cs.off()

  # y is actual line on the screen
  def show_dir_line(self, y):
    if y < 0 or y >= self.screen_y:
      return
    mark = 0
    invert = 0
    if y == self.fb_cursor - self.fb_topitem:
      mark = 1
      invert = 1
    if y == self.fb_selected - self.fb_topitem:
      mark = 2
    i = y+self.fb_topitem
    if i >= len(self.direntries):
      self.osd_print(0,y,0,"%64s" % "")
      return
    if self.direntries[i][1]: # directory
      self.osd_print(0,y,invert,"%c%-57s     D" % (self.mark[mark],self.direntries[i][0]))
    else: # file
      mantissa = self.direntries[i][2]
      exponent = 0
      while mantissa >= 1024:
        mantissa >>= 10
        exponent += 1
      self.osd_print(0,y,invert,"%c%-57s %4d%c" % (self.mark[mark],self.direntries[i][0], mantissa, self.exp_names[exponent]))

  def show_dir(self):
    for i in range(self.screen_y):
      self.show_dir_line(i)

  def move_dir_cursor(self, step):
    oldcursor = self.fb_cursor
    if step == 1:
      if self.fb_cursor < len(self.direntries)-1:
        self.fb_cursor += 1
    if step == -1:
      if self.fb_cursor > 0:
        self.fb_cursor -= 1
    if oldcursor != self.fb_cursor:
      screen_line = self.fb_cursor - self.fb_topitem
      if screen_line >= 0 and screen_line < self.screen_y: # move cursor inside screen, no scroll
        self.show_dir_line(oldcursor - self.fb_topitem) # no highlight
        self.show_dir_line(screen_line) # highlight
      else: # scroll
        if screen_line < 0: # cursor going up
          screen_line = 0
          if self.fb_topitem > 0:
            self.fb_topitem -= 1
            self.show_dir()
        else: # cursor going down
          screen_line = self.screen_y-1
          if self.fb_topitem+self.screen_y < len(self.direntries):
            self.fb_topitem += 1
            self.show_dir()

  def read_dir(self):
    self.direntries = []
    ls = sorted(os.listdir(self.cwd))
    for fname in ls:
      stat = os.stat(self.fullpath(fname))
      if stat[0] & 0o170000 == 0o040000:
        self.direntries.append([fname,1,0]) # directory
    for fname in ls:
      stat = os.stat(self.fullpath(fname))
      if stat[0] & 0o170000 != 0o040000:
        self.direntries.append([fname,0,stat[6]]) # file

  def mdv_skip_preamble(self,n:int)->int:
    i=0
    j=0
    found=0
    while j<n:
      if self.diskfile.readinto(self.mdv_byte):
        if self.mdv_byte[0]==0xFF:
          self.diskfile.readinto(self.mdv_byte)
          if self.mdv_byte[0]==0xFF and i>=10:
            found=1
            i+=2
            break
          else:
            i=0
        else:
          if self.mdv_byte[0]==0:
            i+=1
          else:
            i=0
        j+=1
      else: # EOF, make it circular
        self.diskfile.seek(0)
        print("MDV: wraparound",self.data_buf[2:12].decode("utf-8"))
    if found:
      return i
    return 0
  
  def mdv_refill_buf(self):
    if self.mdv_skip_preamble(1000):
      self.diskfile.readinto(self.data_buf)
      # skip block if header doesn't start with 0xFF
      #i=0
      #while self.data_buf[0]!=0xFF and i<254:
      #  self.mdv_skip_preamble(1000)
      #  self.diskfile.readinto(self.data_buf)
      #  i+=1
      #print(self.data_buf[1],self.data_buf[2:12]) # block number, volume name
      #print(self.data_buf[0:16],self.data_buf[28:32],self.data_buf[40:44]) # block number, volume name
    else:
      print("MDV: preamble not found")

  @micropython.viper
  def mdv_checksum(self,a:int,b:int)->int:
    p8b=ptr8(addressof(self.data_buf))
    c=0xF0F
    i=a
    while i<b:
      c+=p8b[i]
      i+=1
    return c&0xFFFF

  def mdv_read(self):
    if self.mdv_phase[0]:
      self.ctrl(8) # R_cpu_control[3]=1
      self.cs.on()
      self.spi.write(self.spi_send_mdv_bram)
      self.spi.write(self.data_buf[0:16])
      self.cs.off()
      self.ctrl(0)
    else:
      self.ctrl(8)
      self.cs.on()
      self.spi.write(self.spi_send_mdv_bram)
      self.spi.write(self.data_buf[28:32])
      self.spi.write(self.data_buf[40:554])
      self.cs.off()
      self.ctrl(0)
      self.led.on()
      self.mdv_refill_buf()
      # fix checksum in broken MDV images
      #c=self.mdv_checksum(0,14)
      #self.data_buf[14]=c
      #self.data_buf[15]=c>>8
      c=self.mdv_checksum(28,30)
      self.data_buf[30]=c
      self.data_buf[31]=c>>8
      #c=self.mdv_checksum(40,552)
      #self.data_buf[552]=c
      #self.data_buf[553]=c>>8
      self.led.off()
    self.mdv_phase[0]^=1

  # NOTE: this can be used for debugging
  #def osd(self, a):
  #  if len(a) > 0:
  #    enable = 1
  #  else:
  #    enable = 0
  #  self.cs.on()
  #  self.spi.write(bytearray([0,0xFE,0,0,0,enable])) # enable OSD
  #  self.cs.off()
  #  if enable:
  #    self.cs.on()
  #    self.spi.write(bytearray([0,0xFD,0,0,0])) # write content
  #    self.spi.write(bytearray(a)) # write content
  #    self.cs.off()

  def ctrl(self,i):
    self.cs.on()
    self.spi.write(bytearray([0, 0xFF, 0xFF, 0xFF, 0xFF, i]))
    self.cs.off()

  def peek(self,addr,length):
    self.ctrl(4)
    self.ctrl(6)
    self.cs.on()
    self.spi.write(bytearray([1,(addr >> 24) & 0xFF, (addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF, 0]))
    b=bytearray(length)
    self.spi.readinto(b)
    self.cs.off()
    self.ctrl(4)
    self.ctrl(0)
    return b

  def poke(self,addr,data):
    self.ctrl(4)
    self.ctrl(6)
    self.cs.on()
    self.spi.write(bytearray([0,(addr >> 24) & 0xFF, (addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF]))
    self.spi.write(data)
    self.cs.off()
    self.ctrl(4)
    self.ctrl(0)

def peek(addr,length=1):
  return run.peek(addr,length)

def poke(addr,data):
  run.poke(addr,data)

bitstream="/sd/ql/bitstreams/ulx3s_12f_ql.bit"
try:
  os.mount(SDCard(slot=3),"/sd")
  ecp5.prog(bitstream)
except:
  print(bitstream+" file not found")
gc.collect()
run=osd()
