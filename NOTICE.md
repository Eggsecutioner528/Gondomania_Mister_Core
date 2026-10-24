# Gondomania for MiSTer: authorship and notices

Gondomania (Data East DECO8 hardware, 1987) for the MiSTer FPGA platform. Copyright (C) 2026 Eggsecutioner528.
This project's own files carry a copyright and license header and a provenance mark (`GDM-...`). They are licensed under the
GNU General Public License, version 2 or (at your option) any later version (see `LICENSE`). Anyone who copies, adapts or ships any of
them must keep the notice, name the author and publish the complete source of the resulting work under the same license.

## What is original work in this repository
The main board (`rtl/gondo_main.v`), the video block (`rtl/video/gondo_video.v`), the ROM loader, the SDRAM ROM module and the game
version copy engine (`rtl/gondo_loader.v`, `rtl/gondo_gfxrom.v`, `rtl/gondo_vsel.v`), the inputs and sound glue and mixer
(`rtl/gondo_inputs.v`, `rtl/gondo_sound.v`, `rtl/audio_lp.v`), the DDR3 rotation hub (`rtl/ddr_rotate_hub.sv`), the top level additions
in `Gondomania.sv`, the MRA and its generator (`tools/make_mra.py`). The simulation test benches and development tools stay in the author's development repository. They were written by reverse engineering the game from MAME's driver
behavior, the ROM code, the Data East service and technical support manuals, datasheets and the author's own tests. No bitstream of any other core was used.

## Third-party components (kept under their own licenses and notices)
* `rtl/jt65c02`, `rtl/jt12` (JT03/JT12), `rtl/jtopl`, `rtl/jt49`, `rtl/jt8051/jtframe_*`: by Jose Tejada (jotego), part of the JTCORES project, GNU GPL version 3.
* `rtl/jt8051/mc8051.v`: a Verilog translation of Oregano Systems' 8051 core (see `rtl/jt8051/LICENSE`), used through Jose Tejada's `jtframe_8751mcu`.
* `rtl/hd6309/hd6309i.v`: Roger Taylor's Hitachi 6309 version of Greg Miller's MC6809 core (see the file's header).
* `sys/` and the starting point of `Gondomania.sv`, `rtl/sdram.sv`, `rtl/screen_rotate_ex.v`: the MiSTer framework by Sorgelig and the MiSTer contributors, GNU GPL. Changes made here are marked in each file.
* `rtl/jt12` and `rtl/jtopl` are, as their headers state, based on information posted by Nemesis and on Sauraen's VHDL version of OPN/OPN2 (itself based on die shots).
* The behavior of the original hardware was studied through MAME (the MAME team).

## Provenance data in the compiled core
Besides the notices in the source, the compiled core (`.rbf`) carries the author's provenance data, derived from the private salt like the marks above and
placed where it has no effect on how the core behaves. A core that contains it was built from this project's source. Removing it from a copy
is removing copyright management information.

## How to check a suspect file
The author's checking tool is not published; it needs the author's private salt file.

<!-- Gondomania for MiSTer - Copyright (C) 2026 Eggsecutioner528  Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).  Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.  Provenance mark GDM-ec6d6cb6aacd -->
