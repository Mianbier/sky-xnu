#!/usr/bin/env python3
"""
Download only the members we need out of a remote IPSW, via HTTP range requests.

The iPhone X iOS 16.7.16 IPSW is 5.9 GB online / 7.6 GB of members, and we need
three of them. Downloading the whole thing would cost 5.9 GB of runner disk and
bandwidth for files we will never read; the zip central directory tells us the
exact byte ranges, so we fetch just those.

  fetch_ipsw.py URL OUTDIR [MEMBER_SUBSTRING ...]

With no member substrings it lists the archive instead. Members are written via a
.part file and only renamed after the CRC-32 in the central directory matches,
so an interrupted run resumes instead of producing a silently short DMG.

The member names for this build (from BuildManifest.plist):
  OS                = 087-86698-044.dmg   4.7 GB  the root filesystem
  Cryptex1,SystemOS = 087-86593-047.dmg   2.7 GB
  Cryptex1,AppOS    = 087-86715-047.dmg    10 MB
"""
import os
import struct
import subprocess
import sys
import zlib

CHUNK = 8 << 20


def curl(*args):
    return subprocess.run(["curl", "-sfL", *args], check=True, capture_output=True).stdout


def content_length(url):
    for line in curl("-I", url).decode().splitlines():
        if line.lower().startswith("content-length:"):
            return int(line.split(":")[1].strip())
    raise SystemExit("no content-length from " + url)


def central_dir(url):
    """[(name, method, csize, usize, crc, header_off)] from the zip central directory."""
    size = content_length(url)
    tail_len = min(size, 128 * 1024)
    tail = curl("-r", f"{size - tail_len}-{size - 1}", url)
    assert len(tail) == tail_len, "server ignored the range request"

    eocd = -1
    for i in range(len(tail) - 22, -1, -1):
        if tail[i:i + 4] == b"PK\x05\x06":
            eocd = i
            break
    if eocd < 0:
        raise SystemExit("no end-of-central-directory record")

    cd_size, cd_off = struct.unpack_from("<II", tail, eocd + 12)
    if cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF:
        # zip64: locator sits right before the EOCD record
        loc = eocd - 20
        if tail[loc:loc + 4] != b"PK\x06\x07":
            raise SystemExit("zip64 but no locator")
        z64_off, = struct.unpack_from("<Q", tail, loc + 8)
        z64 = curl("-r", f"{z64_off}-{z64_off + 55}", url)
        cd_size, cd_off = struct.unpack_from("<QQ", z64, 40)

    cd = curl("-r", f"{cd_off}-{cd_off + cd_size - 1}", url)
    entries, off = [], 0
    while off + 46 <= len(cd) and cd[off:off + 4] == b"PK\x01\x02":
        method, = struct.unpack_from("<H", cd, off + 10)
        crc, csize, usize = struct.unpack_from("<III", cd, off + 16)
        nlen, elen, clen = struct.unpack_from("<HHH", cd, off + 28)
        hdr_off, = struct.unpack_from("<I", cd, off + 42)
        name = cd[off + 46:off + 46 + nlen].decode(errors="replace")
        if 0xFFFFFFFF in (csize, usize, hdr_off):
            # zip64 extra field
            extra = cd[off + 46 + nlen:off + 46 + nlen + elen]
            p = 0
            while p + 4 <= len(extra):
                tag, ln = struct.unpack_from("<HH", extra, p)
                if tag == 1:
                    q = p + 4
                    if usize == 0xFFFFFFFF:
                        usize, = struct.unpack_from("<Q", extra, q); q += 8
                    if csize == 0xFFFFFFFF:
                        csize, = struct.unpack_from("<Q", extra, q); q += 8
                    if hdr_off == 0xFFFFFFFF:
                        hdr_off, = struct.unpack_from("<Q", extra, q); q += 8
                    break
                p += 4 + ln
        entries.append((name, method, csize, usize, crc, hdr_off))
        off += 46 + nlen + elen + clen
    return entries


def member_data_offset(url, hdr_off):
    """Skip the local file header (its name/extra lengths differ from the CD's)."""
    h = curl("-r", f"{hdr_off}-{hdr_off + 29}", url)
    assert h[:4] == b"PK\x03\x04", "bad local header"
    nlen, elen = struct.unpack_from("<HH", h, 26)
    return hdr_off + 30 + nlen + elen


def download(url, entry, outdir):
    name, method, csize, usize, crc, hdr_off = entry
    path = os.path.join(outdir, os.path.basename(name))
    part = path + ".part"
    if os.path.exists(path) and os.path.getsize(path) == usize:
        print(f"{name}: already present", flush=True)
        return path

    have = os.path.getsize(part) if os.path.exists(part) else 0
    if have > csize:
        have = 0
        os.remove(part)
    base = member_data_offset(url, hdr_off)
    if have:
        print(f"{name}: resuming at {have >> 20} MiB", flush=True)

    mode = "ab" if have else "wb"
    with open(part, mode) as f:
        pos = have
        while pos < csize:
            end = min(pos + CHUNK, csize) - 1
            f.write(curl("-r", f"{base + pos}-{base + end}", url))
            pos = end + 1
            print(f"{name}: {pos * 100 // csize}% ({pos >> 20} MiB)", flush=True)

    if method == 8:
        import zipfile
        raw = zlib.decompressobj(-15)
        data = raw.decompress(open(part, "rb").read()) + raw.flush()
        open(part, "wb").write(data)
    elif method != 0:
        raise SystemExit(f"{name}: unsupported compression method {method}")

    got, n = 0, 0
    with open(part, "rb") as f:
        while chunk := f.read(CHUNK):
            got = zlib.crc32(chunk, got)
            n += len(chunk)
    if n != usize or got != crc:
        raise SystemExit(f"{name}: size/CRC mismatch ({n} vs {usize}, {got:08x} vs {crc:08x})")
    os.replace(part, path)
    print(f"{name}: {usize:,} bytes, CRC-32 ok", flush=True)
    return path


def main(argv):
    url = argv[0]
    entries = central_dir(url)
    if len(argv) < 2:
        for e in entries:
            print(f"{e[3]:>13,} {e[0]}")
        return 0
    outdir = argv[1]
    os.makedirs(outdir, exist_ok=True)
    patterns = argv[2:]
    picked = [e for e in entries if any(p in e[0] for p in patterns)] if patterns else entries
    if not picked:
        raise SystemExit("no member matched")
    for e in picked:
        download(url, e, outdir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
