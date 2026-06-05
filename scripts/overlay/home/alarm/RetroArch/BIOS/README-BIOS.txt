RG DS - RetroArch BIOS / system directory
=========================================

RetroArch is configured to look here for BIOS / firmware files:

    system_directory = "/home/alarm/RetroArch/BIOS"

WHAT IS (AND ISN'T) SHIPPED HERE
--------------------------------
Console BIOS / firmware images (PlayStation, Saturn, Sega CD, Neo Geo, etc.)
are copyrighted by their manufacturers and are NOT freely redistributable, so
this image ships NONE of them. Dump them from hardware you own and drop the
files into this folder (some cores want them in a named subfolder - see below).

The only file pre-placed here is `prboom.wad`, which is the free GPL data file
the PrBoom DOOM core needs - it is not a console BIOS.

The bundled free games are deliberately chosen to need ZERO copyrighted BIOS:
  * DOOM        -> Freedoom (BSD-licensed) + prboom.wad
  * 2048        -> self-contained libretro core
  * Mr.Boom     -> self-contained libretro core
  * Dinothawr   -> libretro's own free game + data
  * Game Boy    -> Gambatte runs with no BIOS

PlayStation note: the PCSX-ReARMed core can run many games with its built-in
HLE BIOS (no file needed). A real scphXXXX.bin improves compatibility.

WHERE FILES GO (drop your own dumps in - filenames are case-sensitive)
----------------------------------------------------------------------
System              File(s)                              MD5
------              -------                              ---
PlayStation (US)    scph5501.bin                         490f666e1afb15b7362b406ed1cea246
PlayStation (JP)    scph5500.bin                         8dd7d5296a650fac7319bce665a6a53c
PlayStation (EU)    scph5502.bin                         32736f17079d0b2b7024407c39bd3050
Sega CD (US)        bios_CD_U.bin                        2efd74e3232ff260e371b99f84024f7f
Sega CD (EU)        bios_CD_E.bin                        e66fa1dc5820d254611fdcdba0662372
Sega CD (JP)        bios_CD_J.bin                        278a9397d192149e84e820ac621a8edd
PC Engine CD        syscard3.pce                         38179df8f4ac870017db21ebcbf53114
Saturn (JP)         sega_101.bin                         85ec9ca47d8f6807718151cbcca8b964
Saturn (US/EU)      mpr-17933.bin                        3240872c70984b6cbfda1586cab68dbe
Game Boy Advance    gba_bios.bin (optional)              a860e8c0b6d573d191e4ec7db1b1e4f6
Atari Lynx          lynxboot.img                         fcd403db69f54290b51035d82f835e7b
Neo Geo             neogeo.zip (keep zipped, for FBNeo)  -

After adding files, verify them in RetroArch:
  Main Menu -> Information -> Core Information, or
  Online Updater -> "System Files" check (Settings > Directory shows this path).

You can confirm a file matches:  md5sum <file>
