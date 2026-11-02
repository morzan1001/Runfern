"""Signing-independent fingerprint of a thin little-endian 64-bit Mach-O."""
import hashlib
import struct


def fingerprint(data):
    if len(data) < 32:
        raise ValueError("Truncated Mach-O")
    header = list(struct.unpack_from("<8I", data))
    if header[0] != 0xFEEDFACF:
        raise ValueError("Expected audited thin 64-bit Mach-O, not fat/unknown format")
    position, commands, sections, signature = 32, [], [], None
    for _ in range(header[4]):
        if position + 8 > len(data):
            raise ValueError("Truncated Mach-O load command")
        command, size = struct.unpack_from("<II", data, position)
        if size < 8 or position + size > 32 + header[5] or position + size > len(data):
            raise ValueError("Invalid Mach-O load command size")
        content = bytearray(data[position:position + size])
        if command == 0x1D:
            if size != 16 or signature is not None:
                raise ValueError("Invalid/duplicate code signature command")
            offset, length = struct.unpack_from("<II", content, 8)
            if offset + length > len(data):
                raise ValueError("Truncated Mach-O signature")
            signature = offset
        else:
            if command == 0x19:
                if size < 72:
                    raise ValueError("Truncated Mach-O segment")
                count = struct.unpack_from("<I", content, 64)[0]
                if size != 72 + count * 80:
                    raise ValueError("Invalid Mach-O section count")
                for index in range(count):
                    offset = struct.unpack_from("<I", content, 72 + index * 80 + 48)[0]
                    if offset:
                        sections.append(offset)
                if content[8:24].rstrip(b"\0") == b"__LINKEDIT":
                    # Signing only extends this segment and appends a signature blob.
                    struct.pack_into("<Q", content, 32, 0)
                    struct.pack_into("<Q", content, 48, 0)
            commands.append(bytes(content))
        position += size
    if position != 32 + header[5] or not sections:
        raise ValueError("Malformed Mach-O command/section layout")
    start = min(sections)
    end = signature if signature is not None else len(data)
    if not position <= start <= end <= len(data):
        raise ValueError("Invalid Mach-O content bounds")
    header[4], header[5] = len(commands), sum(map(len, commands))
    normalized = struct.pack("<8I", *header) + b"".join(commands)
    # Discard only header-room and trailing alignment padding, never code/data.
    normalized += data[start:end].rstrip(b"\0")
    return hashlib.sha256(normalized).hexdigest()
