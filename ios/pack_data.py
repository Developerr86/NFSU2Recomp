#!/usr/bin/env python3
"""Make a smaller copy of the game data for iOS devices (lossless).

    python3 ios/pack_data.py "<game folder>" [out dir]      (default out dir: out/ios-data)

The game folder is only read.  The output folder is a full copy of the game data
in which the files that compress well (track world data, car and wheel models,
front end, cutscene data, ...) are stored in the NFZ1 block format below; every
other file is an APFS clone of the original (no extra disk space on the Mac),
or a plain copy on other file systems.  Push the output folder to the device with
ios/push_data.sh instead of the game folder.

The runtime (runtime/fileio.c) recognises NFZ1 files by their magic and reads them
transparently: the game still sees the original names, sizes and contents.

Not compressed: the movies (VP6 video), the music (PFDATA), the car vinyls and the
speech banks are already compressed (they would shrink by 2-20 %), and SPEED2.EXE
is checked byte for byte at startup.  A file is only stored compressed if that
saves at least MIN_SAVING of it.

NFZ1 layout (little endian):
    0   "NFZ1"
    4   u32  codec       (Apple libcompression id: 0x801 = LZFSE)
    8   u32  block size  (bytes of original data per block)
    12  u32  block count
    16  u64  original size
    24  u32  offsets[count + 1]   file offset of each block, then the end
    ... blocks; a block whose stored length equals its original length is stored raw

Needs macOS (Apple's libcompression, the same library the iOS runtime uses), Python 3.
No game data is written anywhere except the output folder; keep it out of git.
"""
import ctypes, ctypes.util, os, shutil, struct, sys, time
from concurrent.futures import ThreadPoolExecutor

CODEC = 0x801            # COMPRESSION_LZFSE
BLOCK = 128 * 1024
MIN_SIZE = 64 * 1024     # smaller files are not worth it
MIN_SAVING = 0.10
SKIP_DIRS = {"MOVIES", "PFDATA", "SDATA_OLD", "SUPPORT"}
SKIP_NAMES = {"VINYLS.BIN"}
SKIP_EXT = {".exe", ".dll", ".asi", ".vp6", ".big", ".mus", ".log", ".csv", ".rar", ".zip", ".7z"}
MAGIC = b"NFZ1"

lib = ctypes.CDLL("/usr/lib/libcompression.dylib")
lib.compression_encode_buffer.restype = ctypes.c_size_t
lib.compression_encode_buffer.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p,
                                          ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]
lib.compression_decode_buffer.restype = ctypes.c_size_t
lib.compression_decode_buffer.argtypes = lib.compression_encode_buffer.argtypes
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
clonefile = getattr(libc, "clonefile", None)


def encode(raw):
    dst = ctypes.create_string_buffer(len(raw) + 4096)
    n = lib.compression_encode_buffer(dst, len(dst), raw, len(raw), None, CODEC)
    return dst.raw[:n] if 0 < n < len(raw) else raw


def decode(blob, size):
    dst = ctypes.create_string_buffer(size)
    n = lib.compression_decode_buffer(dst, size, blob, len(blob), None, CODEC)
    return dst.raw[:n]


def pack_bytes(data):
    """original bytes -> NFZ1 bytes"""
    blocks = [data[i:i + BLOCK] for i in range(0, len(data), BLOCK)]
    with ThreadPoolExecutor() as ex:
        enc = list(ex.map(encode, blocks))
    head = 24 + 4 * (len(enc) + 1)
    offs, o = [], head
    for b in enc:
        offs.append(o); o += len(b)
    offs.append(o)
    hdr = MAGIC + struct.pack("<III Q", CODEC, BLOCK, len(enc), len(data)) + struct.pack(f"<{len(offs)}I", *offs)
    return hdr + b"".join(enc)


def unpack_bytes(nfz):
    codec, bs, n, size = struct.unpack_from("<IIIQ", nfz, 4)
    offs = struct.unpack_from(f"<{n + 1}I", nfz, 24)
    out = []
    for i in range(n):
        want = min(bs, size - i * bs)
        b = nfz[offs[i]:offs[i + 1]]
        out.append(b if len(b) == want else decode(b, want))
    return b"".join(out)


def wanted(rel, size):
    parts = rel.split(os.sep)
    if len(parts) < 2 or parts[0].upper() in SKIP_DIRS or size < MIN_SIZE:   # files at the top stay as they are
        return False
    name = parts[-1]
    return name.upper() not in SKIP_NAMES and os.path.splitext(name)[1].lower() not in SKIP_EXT


def same_file(src, dst):
    try:
        a, b = os.stat(src), os.stat(dst)
    except FileNotFoundError:
        return False
    return int(b.st_mtime) == int(a.st_mtime)


def clone(src, dst):
    if clonefile is not None and clonefile(src.encode(), dst.encode(), 0) == 0:
        return
    shutil.copy2(src, dst)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    game = os.path.abspath(sys.argv[1])
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "out", "ios-data"))
    if not (os.path.isfile(os.path.join(game, "SPEED2.EXE")) and os.path.isdir(os.path.join(game, "TRACKS"))):
        sys.exit(f"not a game folder: {game}")
    if out == game or out.startswith(game + os.sep):
        sys.exit("the output folder must be outside the game folder")
    t0 = time.time()
    tot_in = tot_out = packed = cloned = kept = 0
    for d, dirs, files in os.walk(game):
        rd = os.path.relpath(d, game)
        dirs[:] = [x for x in dirs if not (rd == "." and x.upper() in SKIP_DIRS - {"MOVIES", "PFDATA"})]
        for f in sorted(files):
            if f == ".DS_Store":
                continue
            src = os.path.join(d, f)
            rel = os.path.normpath(os.path.join(rd, f))
            ext = os.path.splitext(f)[1].lower()
            if ext in {".dll", ".asi"} or (ext == ".exe" and f.upper() != "SPEED2.EXE"):
                continue
            dst = os.path.join(out, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            size = os.path.getsize(src)
            tot_in += size
            if same_file(src, dst):                 # done by an earlier run
                tot_out += os.path.getsize(dst); kept += 1
                continue
            if os.path.lexists(dst):
                os.unlink(dst)
            data = None
            if wanted(rel, size):
                with open(src, "rb") as fh:
                    data = fh.read()
                nfz = pack_bytes(data)
                if len(nfz) <= size * (1 - MIN_SAVING):
                    if unpack_bytes(nfz) != data:    # never ship a file that doesn't round-trip
                        sys.exit(f"round-trip check failed: {rel}")
                    with open(dst + ".tmp", "wb") as fh:
                        fh.write(nfz)
                    os.replace(dst + ".tmp", dst)
                    st = os.stat(src); os.utime(dst, (st.st_atime, st.st_mtime))
                    tot_out += len(nfz); packed += 1
                    print(f"  packed {rel}: {size >> 10} KB -> {len(nfz) >> 10} KB ({100 * len(nfz) // size}%)")
                    continue
            clone(src, dst)
            tot_out += size; cloned += 1
    mb = 1 << 20
    print(f"{packed} files packed, {cloned} copied, {kept} already up to date")
    print(f"game data {tot_in / mb:.0f} MB -> {tot_out / mb:.0f} MB in {out}  ({time.time() - t0:.0f} s)")


if __name__ == "__main__":
    main()
