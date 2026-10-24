# ---------------------------------------------------------------------------------------------------------------------
# Gondomania for MiSTer - Copyright (C) 2026 Eggsecutioner528
# Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
# Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
# Provenance mark GDM-338a3e9d719b
# ---------------------------------------------------------------------------------------------------------------------
"""The ROM sets of Gondomania (World = MAME gondo, US = gondou, Japan = makyosen) and the combined download stream that gondo_loader.v expects.
Used by make_mra.py (the combined MRA) and by the tests (sim_vers/). Files in more than one set are listed once per set with the same name and CRC.

Stream layout (see rtl/gondo_loader.v): background tile ROM (0x60000 bytes, shared), then one block of 0xB9000 bytes per version:
main CPU 0x48000 (16 banks of 16 KB, then the fixed 32 KB), character ROM 0x8000, sprite ROM 0x60000, i8751 MCU ROM 0x1000, sound ROM 0x8000."""
import os, zipfile

ZDIR = os.environ.get("GONDO_ZIPS", "X:/Launchbox/LaunchBox10/Games/Mame/roms2/")
VERSIONS = ["US", "World", "Japan"]          # order = value of the OSD option Game Version
BLOCK = 0xB9000

# logical file -> (zip, name, crc)
def _f(z, n, c): return (z, n, c)
SHARED = {
    "dt01": _f("gondo.zip", "dt01.f5", "c39bb877"),
    "dt06": _f("gondo.zip", "dt06.h7", "3fe1527f"), "dt07": _f("gondo.zip", "dt07.h9", "61f9bce5"), "dt08": _f("gondo.zip", "dt08.h10", "aec483f5"),
    "dt09": _f("gondo.zip", "dt09.h12", "446f0ce0"), "dt10": _f("gondo.zip", "dt10.h13", "cfcfc9ed"), "dt11": _f("gondo.zip", "dt11.h15", "53e9cf17"),
    "dt12": _f("gondo.zip", "dt12.h16", "1a72ca8d"), "dt13": _f("gondo.zip", "dt13.h18", "ccb81aec"),
    "dt15": _f("gondo.zip", "dt15.f8", "a54b2eb6"), "dt16": _f("gondo.zip", "dt16.f9", "e9955d8f"), "dt19": _f("gondo.zip", "dt19.f13", "da2abe4b"),
    "dt21": _f("gondo.zip", "dt21.f16", "1c5f682d"),
}
WORLD = dict(SHARED)
WORLD.update({
    "dt00": _f("gondo.zip", "dt00-e.f3", "912a7eee"), "dt02": _f("gondo.zip", "dt02.f6", "925307a4"), "dt03": _f("gondo.zip", "dt03-e.f7", "ee7475eb"),
    "char": _f("gondo.zip", "dt14-e.b18", "00cbe9c8"), "dt05": _f("gondo.zip", "dt05-e.h5", "ec08aa29"), "mcu": _f("gondo.zip", "dt-e.b1", "0d0532ec"),
    "dt17": _f("gondo.zip", "dt17-e.f11", "75ae349a"), "dt18": _f("gondo.zip", "dt18-e.f12", "2b2d1468"),
    "dt20": _f("gondo.zip", "dt20-e.f15", "0eef7f56"), "dt22": _f("gondo.zip", "dt22-e.f18", "c8ffb148"),
})
US = dict(WORLD)
US.update({
    "dt00": _f("gondou.zip", "dt00.f3", "a8cf9118"), "dt02": _f("gondou.zip", "dt02.f6", "bb5e674b"), "dt03": _f("gondou.zip", "dt03.f7", "99c32b13"),
    "char": _f("gondou.zip", "dt14.b18", "4bef16e1"), "mcu": _f("gondou.zip", "dt-a.b1", "03abceeb"),
    "dt17": _f("gondou.zip", "dt17.f11", "3bbcff0d"), "dt18": _f("gondou.zip", "dt18.f12", "c0c5df1c"),
    "dt20": _f("gondou.zip", "dt20.f15", "42d01002"), "dt22": _f("gondou.zip", "dt22.f18", "c1876a5f"),
})
# Makyou Senshi (Japan, makyosen): the CRCs are MAME's; only these four files are in makyosen.zip, the rest comes from gondo.zip
JAPAN = dict(WORLD)
JAPAN.update({
    "dt00": _f("makyosen.zip", "ds00.f3", "33bb16fe"), "dt03": _f("makyosen.zip", "ds03.f7", "9c0fcbf6"),
    "dt05": _f("makyosen.zip", "ds05.h5", "e6e28ca9"), "mcu": _f("makyosen.zip", "ds.b1", "08f36e35"),
})
SETS = [US, WORLD, JAPAN]
ZIPS = "gondo.zip|gondou.zip|makyosen.zip"

_cache = {}
def read(entry, synth=True):
    """Bytes of one ROM file. A file of makyosen.zip that is not available gets a synthetic stand-in (for tests only)."""
    z, n, c = entry
    if (z, n) in _cache: return _cache[(z, n)]
    path = os.path.join(ZDIR, z)
    if not os.path.exists(path): path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "reference", "roms", z)   # makyosen.zip built from MAME's merged set
    if os.path.exists(path):
        d = zipfile.ZipFile(path).read(n)
    elif z == "makyosen.zip" and synth:
        base = {"ds00.f3": "dt00-e.f3", "ds03.f7": "dt03-e.f7", "ds05.h5": "dt05-e.h5", "ds.b1": "dt-e.b1"}[n]
        d = bytes(b ^ 0x5A for b in zipfile.ZipFile(os.path.join(ZDIR, "gondo.zip")).read(base))
    else:
        raise FileNotFoundError(path)
    _cache[(z, n)] = d
    return d

def tiles(files):
    """Background tile ROM region (0x60000), as MAME assembles it."""
    til = bytearray(0x60000)
    def load(key, off, cont=None):
        d = read(files[key]); til[off:off + 0x8000] = d[:0x8000]
        if cont is not None: til[cont:cont + 0x8000] = d[0x8000:0x10000]
    load("dt08", 0x00000, 0x10000); load("dt09", 0x08000)
    load("dt06", 0x18000, 0x28000); load("dt07", 0x20000)
    load("dt12", 0x30000, 0x40000); load("dt13", 0x38000)
    load("dt10", 0x48000, 0x58000); load("dt11", 0x50000)
    return bytes(til)

def sprites(files):
    spr = bytearray(0x60000)
    for key, off in (("dt19", 0x00000), ("dt20", 0x10000), ("dt16", 0x18000), ("dt18", 0x28000), ("dt15", 0x30000), ("dt17", 0x40000), ("dt21", 0x48000), ("dt22", 0x58000)):
        d = read(files[key]); spr[off:off + len(d)] = d
    return bytes(spr)

def main_rom(files):
    return read(files["dt01"]) + read(files["dt02"]) + read(files["dt03"]) + bytes([0xff]) * 0x10000 + read(files["dt00"])

def block(files):
    """One version's block of the stream."""
    b = main_rom(files) + read(files["char"]) + sprites(files) + read(files["mcu"]) + read(files["dt05"])
    assert len(b) == BLOCK, hex(len(b))
    return b

def stream(sets=SETS):
    return tiles(sets[0]) + b"".join(block(s) for s in sets)
