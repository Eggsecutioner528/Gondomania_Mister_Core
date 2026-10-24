# ---------------------------------------------------------------------------------------------------------------------
# Gondomania for MiSTer - Copyright (C) 2026 Eggsecutioner528
# Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
# Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
# Provenance mark GDM-9f090e7c9cd9
# ---------------------------------------------------------------------------------------------------------------------
"""Writes the MRA of the Gondomania core: ONE file for every version of the game (World, US, Japan). All ROMs of all versions are loaded together
(stream layout in rtl/gondo_loader.v, file sets in tools/gondo_sets.py) and the OSD option Game Version picks the version, like the Battlantis core.
Usage: python tools/make_mra.py <output dir> [--no-japan]   (--no-japan: test MRA for a MiSTer that has no makyosen.zip, the Japan slot repeats the World files)"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gondo_sets as gs

def part(files, key, offset=None, length=None, indent="        "):
    z, n, c = files[key]
    a = ' zip="%s" name="%s" crc="%s"' % (z, n, c)       # every part names its zip: dt02.f6 exists in gondo.zip (World) and in gondou.zip (US)
    if offset is not None: a += ' offset="0x%x" length="0x%x"' % (offset, length)
    return "%s<part%s />\n" % (indent, a)

def tiles_block(f):
    s = ["        <!-- background tile ROM (0x60000), shared by all versions, in the order MAME builds the gfx region -->\n"]
    for k, o in (("dt08", None), ("dt09", None), ("dt08", 1), ("dt06", None), ("dt07", None), ("dt06", 1),
                 ("dt12", None), ("dt13", None), ("dt12", 1), ("dt10", None), ("dt11", None), ("dt10", 1)):
        if k in ("dt09", "dt07", "dt13", "dt11"): s.append(part(f, k))
        elif o is None: s.append(part(f, k, 0, 0x8000))
        else: s.append(part(f, k, 0x8000, 0x8000))
    return "".join(s)

def version_block(title, f):
    s = ["        <!-- %s: main CPU (16 banks of 16 KB, then the fixed 32 KB at 8000-FFFF), character ROM, sprite ROM (0x60000), i8751 MCU ROM (4 KB), sound ROM (32 KB) -->\n" % title]
    s += [part(f, "dt01"), part(f, "dt02"), part(f, "dt03"), '        <part repeat="0x10000">FF</part>\n', part(f, "dt00"), part(f, "char")]
    for k in ("dt19", "dt20", "dt16", "dt18", "dt15", "dt17", "dt21", "dt22"): s.append(part(f, k))
    s += [part(f, "mcu"), part(f, "dt05")]
    return "".join(s)

def build(outdir, no_japan=False):
    sets = [gs.US, gs.WORLD, gs.WORLD] if no_japan else gs.SETS
    zips = "gondo.zip|gondou.zip" if no_japan else gs.ZIPS
    text = ['<misterromdescription>\n    <name>Gondomania</name>\n    <setname>gondo</setname>\n    <rbf>Gondomania</rbf>\n    <mameversion>0266</mameversion>\n',
            '    <year>1987</year>\n    <manufacturer>Data East Corporation</manufacturer>\n    <category>Shooter</category>\n    <players>2</players>\n    <joystick>8-way</joystick>\n    <rotation>vertical (ccw)</rotation>\n',
            '    <buttons names="Button 1,Button 2,Turn Left,Turn Right,Start,Coin" default="A,B,L,R,Start,Select" />\n\n',
            '    <!-- One core, one MRA, three versions: Gondomania (US), Gondomania (World) and Makyou Senshi (Japan).\n'
            '         Pick the version in the OSD (Game Version); the core restarts the game when it changes.\n'
            '         All the ROMs of all the versions are loaded together, in this order:\n'
            '           0x000000 background tile ROM (shared)\n',
            ]
    for i, t in enumerate(gs.VERSIONS):
        text.append('           0x%06X %-6s main CPU, character ROM, sprite ROM, MCU ROM and sound ROM\n' % (0x60000 + i * gs.BLOCK, t))
    text.append('         The files come from gondo.zip (World, and the parts shared by every version), gondou.zip (US) and makyosen.zip (Japan);\n'
                '         all three zips must be present in the games folder (/media/fat/games/mame). -->\n\n')
    text.append('    <!-- High scores: one 72 byte slot per version (US, World, Japan), saved by the OSD button Save High Scores, kept by the MiSTer in\n'
                '         next to its other save files (the file name follows this MRA). -->\n'
                '    <nvram index="1" size="216"/>\n\n')
    text.append('    <rom index="0" zip="%s" md5="none">\n' % zips)
    text.append(tiles_block(gs.WORLD))
    for t, f in zip(gs.VERSIONS, sets): text.append(version_block(t + (' (test: same files as World)' if no_japan and t == 'Japan' else ''), f))
    text.append('    </rom>\n</misterromdescription>\n')
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, "Gondomania.mra")
    open(path, "w", newline="\n").write("".join(text))
    # the release MRA carries the same copyright and provenance line as every other file of ours (tools/add_headers.py)
    if os.path.abspath(path) == os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'mra', 'Gondomania.mra')):
        import add_headers
        add_headers.process('mra/Gondomania.mra', add_headers.salt(), False)
    return path

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "mra"
    print("written", build(out, "--no-japan" in sys.argv))
