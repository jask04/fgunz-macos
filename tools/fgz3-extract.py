#!/usr/bin/env python3
"""
fgz3-extract.py — Extract files from Freestyle GunZ .fgz3 archives

STATUS: Work in progress. Supports standard .fgz (MRS v2) archives with
XOR encryption. The .fgz3 format used by current FGunZ builds uses a
different encryption scheme that is not yet reverse-engineered.

The standard MRS v2 format (used by older GunZ builds):
- Encrypted ZIP variant with XOR-encrypted headers and data
- Header IV: 18 bytes, Data IV: 8 bytes (from MZip.cpp)
- Standard DEFLATE compression

Usage:
    ./tools/fgz3-extract.py <archive.fgz>                   # list contents
    ./tools/fgz3-extract.py <archive.fgz> --extract <dir>   # extract to dir
    ./tools/fgz3-extract.py <archive.fgz> --extract <dir> --filter "*.dds"
"""

import struct
import sys
import os
import zlib
import argparse
import fnmatch
import time

# XOR encryption keys from MZip.cpp
HEADER_IV = bytes([0x05, 0x64, 0x33, 0x99, 0x77, 0x23, 0x11, 0x59,
                   0x91, 0x11, 0x26, 0x21, 0x88, 0x84, 0x75, 0x28,
                   0x33, 0x15])

DATA_IV = bytes([0x22, 0x01, 0x57, 0x43, 0x24, 0x68, 0x87, 0x22])

# Signatures
ZIP_LOCAL_SIG = 0x04034b50
MRS1_LOCAL_SIG = 0x85840000
ZIP_CENTRAL_SIG = 0x02014b50
MRS1_CENTRAL_SIG = 0x05024b80
ZIP_END_SIG = 0x06054b50
MRS_ZIP_CODE = 0x05030207
MRS2_ZIP_CODE = 0x05030208

# Compression methods
COMP_STORE = 0
COMP_DEFLATE = 8


def xor_decrypt(data: bytes, iv: bytes) -> bytearray:
    """XOR-decrypt data using a cycling IV."""
    result = bytearray(data)
    iv_len = len(iv)
    for i in range(len(result)):
        result[i] ^= iv[i % iv_len]
    return result


def mrs1_decrypt_byte(b):
    """Mrs v1 per-byte decryption (inverse of ConvertChar)."""
    # ConvertChar: XOR 0xFF, rotate left 3
    # Reverse: rotate right 3, XOR 0xFF
    b = ((b >> 3) | (b << 5)) & 0xFF
    return b ^ 0xFF


def mrs1_decrypt(data: bytes) -> bytearray:
    """Mrs v1 decryption."""
    return bytearray(mrs1_decrypt_byte(b) for b in data)


def dos_datetime_to_unix(mod_time, mod_date):
    """Convert DOS date/time to Unix timestamp."""
    second = (mod_time & 0x1F) * 2
    minute = (mod_time >> 5) & 0x3F
    hour = (mod_time >> 11) & 0x1F
    day = mod_date & 0x1F
    month = (mod_date >> 5) & 0x0F
    year = ((mod_date >> 9) & 0x7F) + 1980
    try:
        import calendar
        return calendar.timegm((year, month, day, hour, minute, second, 0, 0, 0))
    except (ValueError, OverflowError):
        return 0


class FGZ3Entry:
    """Represents a file entry in an .fgz3 archive."""
    def __init__(self):
        self.filename = ""
        self.compressed_size = 0
        self.uncompressed_size = 0
        self.compression = 0
        self.crc32 = 0
        self.header_offset = 0
        self.mod_time = 0
        self.mod_date = 0

    @property
    def unix_time(self):
        return dos_datetime_to_unix(self.mod_time, self.mod_date)

    @property
    def is_compressed(self):
        return self.compression == COMP_DEFLATE


class FGZ3Archive:
    """Read and extract files from .fgz3 (MRS v2 encrypted ZIP) archives."""

    def __init__(self, filepath):
        self.filepath = filepath
        self.entries = []
        self.mode = None  # 'zip', 'mrs1', 'mrs2'
        self._detect_and_parse()

    def _detect_and_parse(self):
        """Detect archive type and parse the central directory."""
        with open(self.filepath, 'rb') as f:
            magic = struct.unpack('<I', f.read(4))[0]

            if magic == ZIP_LOCAL_SIG:
                self.mode = 'zip'
            elif magic == MRS1_LOCAL_SIG:
                self.mode = 'mrs1'
            else:
                self.mode = 'mrs2'

            self._parse_central_directory(f)

    def _parse_central_directory(self, f):
        """Parse the end-of-central-directory and central directory entries."""
        # Read end-of-central-directory (last 22 bytes)
        f.seek(0, 2)
        file_size = f.tell()

        # Search for end-of-central-directory record
        # It should be at the very end (22 bytes) unless there's a comment
        search_start = max(0, file_size - 65557)  # max comment = 65535
        f.seek(search_start)
        search_data = f.read()

        eocd_offset = -1
        # For mrs2, we need to try decrypting potential EOCD locations
        if self.mode == 'mrs2':
            # Try the last 22 bytes first (most common case)
            eocd_data = search_data[-22:]
            decrypted = xor_decrypt(eocd_data, HEADER_IV)
            sig = struct.unpack('<I', decrypted[:4])[0]
            if sig in (ZIP_END_SIG, MRS_ZIP_CODE, MRS2_ZIP_CODE):
                eocd_offset = file_size - 22
                eocd_raw = decrypted
            else:
                # Search backwards
                for i in range(len(search_data) - 22, -1, -1):
                    candidate = search_data[i:i+22]
                    dec = xor_decrypt(candidate, HEADER_IV)
                    s = struct.unpack('<I', dec[:4])[0]
                    if s in (ZIP_END_SIG, MRS_ZIP_CODE, MRS2_ZIP_CODE):
                        eocd_offset = search_start + i
                        eocd_raw = dec
                        break
        elif self.mode == 'mrs1':
            # Mrs v1 uses mrs1_decrypt
            eocd_data = search_data[-22:]
            decrypted = mrs1_decrypt(eocd_data)
            sig = struct.unpack('<I', decrypted[:4])[0]
            if sig in (ZIP_END_SIG, MRS_ZIP_CODE):
                eocd_offset = file_size - 22
                eocd_raw = decrypted
        else:
            # Plain ZIP
            for i in range(len(search_data) - 22, -1, -1):
                sig = struct.unpack('<I', search_data[i:i+4])[0]
                if sig == ZIP_END_SIG:
                    eocd_offset = search_start + i
                    eocd_raw = bytearray(search_data[i:i+22])
                    break

        if eocd_offset < 0:
            raise ValueError(f"Could not find end-of-central-directory in {self.filepath}")

        # Parse EOCD: sig(4), nDisk(2), nStartDisk(2), nDirEntries(2),
        #             totalDirEntries(2), dirSize(4), dirOffset(4), cmntLen(2)
        (_, n_disk, n_start_disk, n_dir_entries, total_dir_entries,
         dir_size, dir_offset, cmnt_len) = struct.unpack('<IHHHHIIH', eocd_raw[:22])

        # The dirOffset in mrs2 is relative to start of file
        # but dirSize tells us how large the central directory is
        # Central directory starts at: eocd_offset - dir_size (in some implementations)
        # or at dir_offset (absolute). Let's try dir_offset first.
        cd_start = dir_offset

        # Read central directory
        f.seek(cd_start)
        cd_data = f.read(dir_size)

        if self.mode == 'mrs2':
            self._parse_cd_mrs2(cd_data, total_dir_entries)
        elif self.mode == 'mrs1':
            self._parse_cd_mrs1(cd_data, total_dir_entries)
        else:
            self._parse_cd_zip(cd_data, total_dir_entries)

    def _parse_cd_mrs2(self, cd_data, num_entries):
        """Parse central directory entries for Mrs v2 (XOR encrypted)."""
        offset = 0
        for _ in range(num_entries):
            if offset + 46 > len(cd_data):
                break

            # Decrypt fixed 46-byte header
            header_raw = xor_decrypt(cd_data[offset:offset+46], HEADER_IV)
            (sig, ver_made, ver_needed, flag, compression,
             mod_time, mod_date, crc32, c_size, uc_size,
             fname_len, xtra_len, cmnt_len, disk_start,
             int_attr, ext_attr, hdr_offset) = struct.unpack(
                '<IHHHHHHIIIHHHHHII', header_raw)

            # Validate signature
            if sig not in (ZIP_CENTRAL_SIG, MRS1_CENTRAL_SIG):
                # Try without decryption in case of mixed format
                break

            # Decrypt filename
            fname_start = offset + 46
            fname_raw = xor_decrypt(cd_data[fname_start:fname_start+fname_len], HEADER_IV)
            filename = fname_raw.decode('ascii', errors='replace').replace('/', '\\')

            entry = FGZ3Entry()
            entry.filename = filename
            entry.compressed_size = c_size
            entry.uncompressed_size = uc_size
            entry.compression = compression
            entry.crc32 = crc32
            entry.header_offset = hdr_offset
            entry.mod_time = mod_time
            entry.mod_date = mod_date
            self.entries.append(entry)

            offset = fname_start + fname_len + xtra_len + cmnt_len

    def _parse_cd_mrs1(self, cd_data, num_entries):
        """Parse central directory entries for Mrs v1."""
        offset = 0
        for _ in range(num_entries):
            if offset + 46 > len(cd_data):
                break
            header_raw = mrs1_decrypt(cd_data[offset:offset+46])
            (sig, ver_made, ver_needed, flag, compression,
             mod_time, mod_date, crc32, c_size, uc_size,
             fname_len, xtra_len, cmnt_len, disk_start,
             int_attr, ext_attr, hdr_offset) = struct.unpack(
                '<IHHHHHHIIIHHHHHII', header_raw)

            fname_start = offset + 46
            fname_raw = mrs1_decrypt(cd_data[fname_start:fname_start+fname_len])
            filename = fname_raw.decode('ascii', errors='replace').replace('/', '\\')

            entry = FGZ3Entry()
            entry.filename = filename
            entry.compressed_size = c_size
            entry.uncompressed_size = uc_size
            entry.compression = compression
            entry.crc32 = crc32
            entry.header_offset = hdr_offset
            entry.mod_time = mod_time
            entry.mod_date = mod_date
            self.entries.append(entry)

            offset = fname_start + fname_len + xtra_len + cmnt_len

    def _parse_cd_zip(self, cd_data, num_entries):
        """Parse central directory entries for plain ZIP."""
        offset = 0
        for _ in range(num_entries):
            if offset + 46 > len(cd_data):
                break
            (sig, ver_made, ver_needed, flag, compression,
             mod_time, mod_date, crc32, c_size, uc_size,
             fname_len, xtra_len, cmnt_len, disk_start,
             int_attr, ext_attr, hdr_offset) = struct.unpack(
                '<IHHHHHHIIIHHHHHII', cd_data[offset:offset+46])

            if sig != ZIP_CENTRAL_SIG:
                break

            fname_start = offset + 46
            filename = cd_data[fname_start:fname_start+fname_len].decode('ascii', errors='replace')

            entry = FGZ3Entry()
            entry.filename = filename
            entry.compressed_size = c_size
            entry.uncompressed_size = uc_size
            entry.compression = compression
            entry.crc32 = crc32
            entry.header_offset = hdr_offset
            entry.mod_time = mod_time
            entry.mod_date = mod_date
            self.entries.append(entry)

            offset = fname_start + fname_len + xtra_len + cmnt_len

    def read_file(self, entry: FGZ3Entry) -> bytes:
        """Read and decrypt a single file from the archive."""
        with open(self.filepath, 'rb') as f:
            f.seek(entry.header_offset)
            local_header_raw = f.read(30)

            if self.mode == 'mrs2':
                local_header = xor_decrypt(local_header_raw, HEADER_IV)
            elif self.mode == 'mrs1':
                local_header = mrs1_decrypt(local_header_raw)
            else:
                local_header = bytearray(local_header_raw)

            (sig, version, flag, compression, mod_time, mod_date,
             crc32, c_size, uc_size, fname_len, xtra_len) = struct.unpack(
                '<IHHHHHIIIHH', local_header)

            # Skip filename and extra field
            f.seek(entry.header_offset + 30 + fname_len + xtra_len)

            # Read compressed data
            compressed_data = f.read(entry.compressed_size)

            # Decrypt data
            if self.mode == 'mrs2':
                compressed_data = xor_decrypt(compressed_data, DATA_IV)
            elif self.mode == 'mrs1':
                compressed_data = mrs1_decrypt(compressed_data)

            # Decompress if needed
            if entry.compression == COMP_DEFLATE:
                try:
                    data = zlib.decompress(bytes(compressed_data), -zlib.MAX_WBITS)
                except zlib.error as e:
                    print(f"  WARNING: Failed to decompress {entry.filename}: {e}",
                          file=sys.stderr)
                    return b''
            elif entry.compression == COMP_STORE:
                data = bytes(compressed_data)
            else:
                print(f"  WARNING: Unknown compression {entry.compression} for {entry.filename}",
                      file=sys.stderr)
                return b''

            # CRC32 verification
            actual_crc = zlib.crc32(data) & 0xFFFFFFFF
            if actual_crc != entry.crc32:
                print(f"  WARNING: CRC mismatch for {entry.filename}: "
                      f"expected {entry.crc32:#010x}, got {actual_crc:#010x}",
                      file=sys.stderr)

            return data

    def list_files(self):
        """Print a listing of all files in the archive."""
        total_compressed = 0
        total_uncompressed = 0

        print(f"Archive: {self.filepath}")
        print(f"Format:  {self.mode}")
        print(f"Files:   {len(self.entries)}")
        print()
        print(f"{'Size':>10}  {'Compressed':>10}  {'Ratio':>6}  {'Method':>7}  Name")
        print(f"{'─'*10}  {'─'*10}  {'─'*6}  {'─'*7}  {'─'*40}")

        for entry in sorted(self.entries, key=lambda e: e.filename):
            ratio = 0
            if entry.uncompressed_size > 0:
                ratio = 100 - (entry.compressed_size / entry.uncompressed_size * 100)
            method = "DEFLATE" if entry.is_compressed else "STORE"
            print(f"{entry.uncompressed_size:>10}  {entry.compressed_size:>10}  "
                  f"{ratio:>5.1f}%  {method:>7}  {entry.filename}")
            total_compressed += entry.compressed_size
            total_uncompressed += entry.uncompressed_size

        print(f"{'─'*10}  {'─'*10}")
        ratio = 0
        if total_uncompressed > 0:
            ratio = 100 - (total_compressed / total_uncompressed * 100)
        print(f"{total_uncompressed:>10}  {total_compressed:>10}  "
              f"{ratio:>5.1f}%  {'':>7}  {len(self.entries)} files")

    def extract_all(self, output_dir, filter_pattern=None):
        """Extract all (or filtered) files to a directory."""
        os.makedirs(output_dir, exist_ok=True)
        extracted = 0
        skipped = 0
        errors = 0
        total_bytes = 0

        for entry in self.entries:
            # Apply filter
            if filter_pattern:
                if not fnmatch.fnmatch(entry.filename.lower(), filter_pattern.lower()):
                    skipped += 1
                    continue

            # Build output path (convert backslashes to forward slashes)
            rel_path = entry.filename.replace('\\', os.sep)
            out_path = os.path.join(output_dir, rel_path)

            # Create directories
            os.makedirs(os.path.dirname(out_path), exist_ok=True)

            try:
                data = self.read_file(entry)
                if not data and entry.uncompressed_size > 0:
                    errors += 1
                    continue

                with open(out_path, 'wb') as out_f:
                    out_f.write(data)

                # Set modification time
                if entry.unix_time > 0:
                    os.utime(out_path, (entry.unix_time, entry.unix_time))

                extracted += 1
                total_bytes += len(data)

                if extracted % 100 == 0:
                    print(f"  Extracted {extracted} files ({total_bytes / 1024 / 1024:.1f} MB)...")

            except Exception as e:
                print(f"  ERROR extracting {entry.filename}: {e}", file=sys.stderr)
                errors += 1

        return extracted, skipped, errors, total_bytes


def main():
    parser = argparse.ArgumentParser(
        description='Extract files from FGunZ .fgz3 archives')
    parser.add_argument('archive', help='Path to .fgz3 archive')
    parser.add_argument('--extract', '-x', metavar='DIR',
                        help='Extract files to directory')
    parser.add_argument('--filter', '-f', metavar='PATTERN',
                        help='Filter files by glob pattern (e.g., "*.dds", "Interface/*")')
    parser.add_argument('--verify', '-v', action='store_true',
                        help='Verify CRC32 of all files without extracting')
    args = parser.parse_args()

    if not os.path.isfile(args.archive):
        print(f"ERROR: File not found: {args.archive}", file=sys.stderr)
        sys.exit(1)

    try:
        archive = FGZ3Archive(args.archive)
    except Exception as e:
        print(f"ERROR: Failed to open archive: {e}", file=sys.stderr)
        sys.exit(1)

    if args.extract:
        print(f"Extracting {args.archive} -> {args.extract}")
        if args.filter:
            print(f"Filter: {args.filter}")
        print()

        start_time = time.time()
        extracted, skipped, errors, total_bytes = archive.extract_all(
            args.extract, args.filter)
        elapsed = time.time() - start_time

        print()
        print(f"Done in {elapsed:.1f}s: {extracted} extracted, "
              f"{skipped} skipped, {errors} errors, "
              f"{total_bytes / 1024 / 1024:.1f} MB")
    elif args.verify:
        print(f"Verifying {args.archive}...")
        ok = 0
        fail = 0
        for entry in archive.entries:
            data = archive.read_file(entry)
            actual_crc = zlib.crc32(data) & 0xFFFFFFFF
            if actual_crc == entry.crc32:
                ok += 1
            else:
                print(f"  FAIL: {entry.filename} "
                      f"(expected {entry.crc32:#010x}, got {actual_crc:#010x})")
                fail += 1
        print(f"\n{ok} OK, {fail} failed out of {len(archive.entries)} files")
    else:
        archive.list_files()


if __name__ == '__main__':
    main()
