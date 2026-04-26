#!/bin/sh

rm -f dist/kernal.bin dist/basic.bin dist/char.bin dist/c1541_rom.bin dist/arv6-cl-fix.crt dist/ar6_pal.bin

wget "https://github.com/MEGA65/open-roms/raw/refs/heads/master/bin/kernal_generic.rom" -O dist/kernal.bin
wget "https://github.com/MEGA65/open-roms/raw/refs/heads/master/bin/basic_generic.rom" -O dist/basic.bin
wget "https://github.com/MEGA65/open-roms/raw/refs/heads/master/bin/chargen_pxlfont_2.3.rom" -O dist/char.bin
wget "https://www.zimmers.net/anonftp/pub/cbm/firmware/drives/new/1541/1541-II.251968-03.bin" -O dist/c1541_rom.bin
