#!/bin/sh

rm -f dist/kernal.bin dist/basic.bin dist/char.bin dist/c1541_rom.bin dist/arv6-cl-fix.crt dist/ar6_pal.bin

wget "https://github.com/ytmytm/1541-RAMBOardII/raw/refs/heads/main/rom/DolphinDOS2-Kernal-C64.rom" -O dist/kernal_dd2.bin
wget "https://www.zimmers.net/anonftp/pub/cbm/firmware/computers/c64/kernal.901227-02.bin" -O dist/kernal.bin
wget "https://www.zimmers.net/anonftp/pub/cbm/firmware/computers/c64/basic.901226-01.bin" -O dist/basic.bin

if [ -z "$1" ] ; then
    wget "https://www.zimmers.net/anonftp/pub/cbm/firmware/computers/c64/characters.901225-01.bin" -O dist/char.bin
else
    wget "https://github.com/MEGA65/open-roms/raw/refs/heads/master/bin/chargen_pxlfont_2.3.rom" -O dist/char.bin
fi

wget "https://www.zimmers.net/anonftp/pub/cbm/firmware/drives/new/1541/1541-II.251968-03.bin" -O dist/c1541_rom.bin
wget "https://github.com/ytmytm/1541-RAMBOardII/raw/refs/heads/main/rom/DolphinDOS2-1541-II.bin" -O dist/c1541_rom_ext.bin

wget "https://csdb.dk/release/download.php?id=318187" \
    --header "Cache-Control: no-cache" \
    --header "Pragma: no-cache" \
    --header "Referer: https://csdb.dk/release/?id=258640" \
    --header "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36" \
    -O dist/arv6-cl-fix.crt

wget "https://csdb.dk/release/download.php?id=243774" \
    --header "Cache-Control: no-cache" \
    --header "Pragma: no-cache" \
    --header "Referer: https://csdb.dk/release/?id=258640" \
    --header "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36" \
    -O dist/rr38p-tmp12-patched.zip

python3 ar_extract.py dist/arv6-cl-fix.crt dist/ar6_pal.bin
rm -f dist/arv6-cl-fix.crt

unzip -j dist/rr38p-tmp12-patched.zip rr38p-tmp12-patched/rr38p-tmp12.bin rr38p-tmp12-patched/rr38p-tmp12reu.bin
rm -f dist/rr38p-tmp12-patched.zip
mv rr38p-tmp12.bin dist/rr6_pal.bin
mv rr38p-tmp12reu.bin dist/rr6_pal_reu.bin
