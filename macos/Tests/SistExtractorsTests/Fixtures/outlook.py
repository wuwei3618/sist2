"""Writes Outlook .msg ([MS-OXMSG] in a [MS-CFB] compound file) and .pst ([MS-PST]) fixtures.

No tool on Linux writes these formats, so they are written here, from the specifications, and
checked with independent readers before being used: olefile and extract-msg for .msg, libpst's
readpst and libpff (pypff) for .pst. See generate.py.
"""
import struct

# MAPI property types
PT_INT32 = 0x0003
PT_BOOLEAN = 0x000B
PT_OBJECT = 0x000D
PT_INT64 = 0x0014
PT_STRING8 = 0x001E  # 8-bit text in the message's code page; values are given as bytes
PT_STRING = 0x001F
PT_TIME = 0x0040
PT_BINARY = 0x0102

FIXED_SIZES = {PT_INT32: 4, PT_BOOLEAN: 1, PT_INT64: 8, PT_TIME: 8}


def filetime(unix):
    return (unix + 11644473600) * 10_000_000


def encode_value(ptype, value):
    if ptype == PT_STRING:
        return value.encode("utf-16-le")
    if ptype in (PT_BINARY, PT_STRING8):
        return bytes(value)
    if ptype == PT_INT32:
        return struct.pack("<I", value)
    if ptype == PT_BOOLEAN:
        return struct.pack("<B", 1 if value else 0)
    if ptype in (PT_INT64, PT_TIME):
        return struct.pack("<Q", value)
    raise ValueError(ptype)


# ---------------------------------------------------------------------------------------------
# Compound File Binary, version 3 (512-byte sectors)

FREESECT, ENDOFCHAIN, FATSECT, NOSTREAM = 0xFFFFFFFF, 0xFFFFFFFE, 0xFFFFFFFD, 0xFFFFFFFF


class Storage:
    def __init__(self, name):
        self.name = name
        self.children = []  # Storage or (name, bytes)

    def stream(self, name, data):
        self.children.append((name, bytes(data)))
        return self

    def storage(self, name):
        child = Storage(name)
        self.children.append(child)
        return child


def cfb_key(name):
    # Siblings are ordered by name length, then by upper-cased name
    return (len(name), name.upper())


def write_cfb(root):
    entries = []  # dicts: name, type, data, children(list of indexes)

    def add(node, is_root=False):
        index = len(entries)
        if isinstance(node, Storage):
            entries.append({"name": "Root Entry" if is_root else node.name, "type": 5 if is_root else 1,
                            "data": b"", "kids": []})
            kids = [add(child) for child in node.children]
            entries[index]["kids"] = kids
        else:
            name, data = node
            entries.append({"name": name, "type": 2, "data": data, "kids": []})
        return index

    add(root, is_root=True)

    # Each storage's children as a balanced binary search tree; every node black
    for entry in entries:
        entry.setdefault("left", NOSTREAM)
        entry.setdefault("right", NOSTREAM)
        entry.setdefault("child", NOSTREAM)

    def build(indexes):
        if not indexes:
            return NOSTREAM
        indexes = sorted(indexes, key=lambda i: cfb_key(entries[i]["name"]))
        middle = len(indexes) // 2
        node = indexes[middle]
        entries[node]["left"] = build(indexes[:middle])
        entries[node]["right"] = build(indexes[middle + 1:])
        return node

    for entry in entries:
        if entry["kids"]:
            entry["child"] = build(entry["kids"])

    sector = 512
    sectors = []  # bytes of each regular sector
    fat = []

    def allocate(data):
        if not data:
            return ENDOFCHAIN
        first = len(sectors)
        chunks = [data[i:i + sector] for i in range(0, len(data), sector)]
        for n, chunk in enumerate(chunks):
            sectors.append(chunk.ljust(sector, b"\0"))
            fat.append(first + n + 1 if n + 1 < len(chunks) else ENDOFCHAIN)
        return first

    # Small streams go to the mini stream, in 64-byte sectors
    mini = bytearray()
    minifat = []
    for entry in entries:
        if entry["type"] == 2 and len(entry["data"]) < 4096:
            data = entry["data"]
            if not data:
                entry["start"] = ENDOFCHAIN
                continue
            first = len(mini) // 64
            count = (len(data) + 63) // 64
            mini += data.ljust(count * 64, b"\0")
            for n in range(count):
                minifat.append(first + n + 1 if n + 1 < count else ENDOFCHAIN)
            entry["start"] = first
    for entry in entries:
        if entry["type"] == 2 and len(entry["data"]) >= 4096:
            entry["start"] = allocate(entry["data"])
    entries[0]["start"] = allocate(bytes(mini))
    entries[0]["data"] = bytes(mini)
    minifat_bytes = b"".join(struct.pack("<I", v) for v in minifat)
    minifat_start = allocate(minifat_bytes) if minifat else ENDOFCHAIN
    minifat_count = (len(minifat_bytes) + sector - 1) // sector

    directory = bytearray()
    for entry in entries:
        name = entry["name"].encode("utf-16-le")
        record = bytearray(128)
        record[0:len(name)] = name
        struct.pack_into("<H", record, 0x40, len(name) + 2)
        record[0x42] = entry["type"]
        record[0x43] = 1
        struct.pack_into("<III", record, 0x44, entry["left"], entry["right"], entry["child"])
        struct.pack_into("<I", record, 0x74, entry.get("start", ENDOFCHAIN) if entry["type"] != 1 else 0)
        struct.pack_into("<Q", record, 0x78, len(entry["data"]) if entry["type"] != 1 else 0)
        directory += record
    while len(directory) % sector:
        directory += bytearray(128)
        struct.pack_into("<III", directory, len(directory) - 128 + 0x44, NOSTREAM, NOSTREAM, NOSTREAM)
    directory_start = allocate(bytes(directory))

    # The FAT describes itself too
    fat_sectors = 1
    while (len(fat) + fat_sectors) > fat_sectors * (sector // 4):
        fat_sectors += 1
    assert fat_sectors <= 109
    fat_first = len(sectors)
    for n in range(fat_sectors):
        fat.append(FATSECT)
        sectors.append(b"")
    fat_bytes = b"".join(struct.pack("<I", v) for v in fat).ljust(fat_sectors * sector, b"\xff")
    for n in range(fat_sectors):
        sectors[fat_first + n] = fat_bytes[n * sector:(n + 1) * sector]

    header = bytearray(512)
    header[0:8] = bytes([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    struct.pack_into("<HHHHH", header, 0x18, 0x3E, 3, 0xFFFE, 9, 6)
    struct.pack_into("<I", header, 0x2C, fat_sectors)
    struct.pack_into("<I", header, 0x30, directory_start)
    struct.pack_into("<I", header, 0x38, 4096)
    struct.pack_into("<II", header, 0x3C, minifat_start, minifat_count)
    struct.pack_into("<II", header, 0x44, ENDOFCHAIN, 0)
    for n in range(109):
        struct.pack_into("<I", header, 0x4C + n * 4, fat_first + n if n < fat_sectors else FREESECT)
    return bytes(header) + b"".join(sectors)


# ---------------------------------------------------------------------------------------------
# .msg

def substg(tag_id, ptype):
    return "__substg1.0_%04X%04X" % (tag_id, ptype)


def property_stream(header, properties):
    """properties: (id, type, value). Fixed-size values inline, others as their size."""
    out = bytearray(header)
    for tag_id, ptype, value in properties:
        tag = (tag_id << 16) | ptype
        if ptype in FIXED_SIZES:
            raw = encode_value(ptype, value).ljust(8, b"\0")
        else:
            size = len(encode_value(ptype, value)) + (2 if ptype == PT_STRING else 0)
            raw = struct.pack("<II", size, 0)
        out += struct.pack("<II", tag, 6) + raw
    return bytes(out)


def add_properties(storage, header, properties):
    for tag_id, ptype, value in properties:
        if ptype not in FIXED_SIZES:
            storage.stream(substg(tag_id, ptype), encode_value(ptype, value))
    storage.stream("__properties_version1.0", property_stream(header, properties))


def write_msg(subject, sender_name, sender_email, to, cc, body, html, sent, recipients, attachments):
    """attachments: (long file name, bytes)"""
    root = Storage("Root Entry")
    named = root.storage("__nameid_version1.0")
    named.stream(substg(0x0002, PT_BINARY), b"")
    named.stream(substg(0x0003, PT_BINARY), b"")
    named.stream(substg(0x0004, PT_BINARY), b"")

    properties = [
        (0x001A, PT_STRING, "IPM.Note"),
        (0x0037, PT_STRING, subject),
        (0x0E1D, PT_STRING, subject),
        (0x0C1A, PT_STRING, sender_name),
        (0x0C1F, PT_STRING, sender_email),
        (0x0C1E, PT_STRING, "SMTP"),
        (0x0042, PT_STRING, sender_name),
        (0x0E04, PT_STRING, to),
        (0x0E03, PT_STRING, cc),
        (0x1000, PT_STRING, body),
        (0x0039, PT_TIME, filetime(sent)),
        (0x0E06, PT_TIME, filetime(sent)),
        (0x0E07, PT_INT32, 0x11 if attachments else 0x01),
        (0x3FDE, PT_INT32, 65001),
    ]
    if html is not None:
        properties.append((0x1013, PT_BINARY, html.encode("utf-8")))
    header = struct.pack("<8sIIII8s", b"", len(recipients), len(attachments), len(recipients), len(attachments), b"")
    add_properties(root, header, properties)

    for n, (name, email, kind) in enumerate(recipients):
        recipient = root.storage("__recip_version1.0_#%08X" % n)
        add_properties(recipient, b"\0" * 8, [
            (0x3001, PT_STRING, name), (0x3003, PT_STRING, email), (0x39FE, PT_STRING, email),
            (0x3002, PT_STRING, "SMTP"), (0x0C15, PT_INT32, kind), (0x3000, PT_INT32, n),
        ])
    for n, (name, data) in enumerate(attachments):
        attachment = root.storage("__attach_version1.0_#%08X" % n)
        add_properties(attachment, b"\0" * 8, [
            (0x3707, PT_STRING, name), (0x3704, PT_STRING, name[:8]), (0x3001, PT_STRING, name),
            (0x3701, PT_BINARY, data), (0x3705, PT_INT32, 1), (0x0E20, PT_INT32, len(data)),
            (0x370B, PT_INT32, -1 & 0xFFFFFFFF), (0x0E21, PT_INT32, n),
        ])
    return write_cfb(root)


# ---------------------------------------------------------------------------------------------
# .pst: Unicode (wVer 23) or ANSI (wVer 14) format, 512-byte pages, compressible ("permute")
# encryption. The ANSI format has 32-bit block ids, node ids and offsets, and its own layouts.

import zlib

# mpbbR of [MS-PST] 5.1: data blocks are encoded with it, and decoded with its inverse
PERMUTE = bytes.fromhex(
    "41361362a8216ebbf416cc047f64e85d1ef2cb2a74c55e35d295479e962d9a884c7d843fdbac31b6485ff6c4d8398be7"
    "233b388ec8c1df25b120a546604e9cfbaad35651457c550007c92b9d859b09a08fadb30f63ab894bd7a7155a716642bf"
    "264a6b98faea7753b270052cfd593a867ece06eb827857c78d43afb41cd45bcde2e9274fc3087280cfb0eff5286dbe30"
    "4d3492d50e3c2232e5e4f99fc2d10a8112e1ee918376e397e6618a1779a4b7dc907a5c8c02a6ca69de501a1193b95287"
    "58fced1d37491b6ae0293399bd6cd994f340546ff0c673b8d63e6518441fdd6710f10c19ecae03a1147ba90bfff8a3c0"
    "a201f72ebc2468750dfeba2fb5d0da3d")

NID_MESSAGE_STORE, NID_NAME_TO_ID_MAP, NID_ROOT_FOLDER = 0x21, 0x61, 0x122
NID_RECIPIENT_TABLE, NID_ATTACHMENT_TABLE = 0x692, 0x671
TYPE_FOLDER, TYPE_MESSAGE, TYPE_ATTACHMENT, TYPE_LTP = 0x02, 0x04, 0x05, 0x1F
TYPE_HIERARCHY, TYPE_CONTENTS, TYPE_ASSOC = 0x0D, 0x0E, 0x0F
MAX_BLOCK, MAX_ALLOCATION = 8176, 3580


def pst_crc(data):
    # [MS-PST] 5.3: CRC-32 without the initial and final inversion
    return zlib.crc32(data, 0xFFFFFFFF) ^ 0xFFFFFFFF


def signature(ib, bid):
    ib ^= bid
    return ((ib >> 16) ^ ib) & 0xFFFF


def align(value, to):
    return (value + to - 1) // to * to


class Heap:
    """A heap-on-node of one block: allocations addressed by HID"""

    def __init__(self, client_signature):
        self.client_signature = client_signature
        self.allocations = []

    def alloc(self, data):
        self.allocations.append(bytes(data))
        return len(self.allocations) << 5

    def build(self, user_root):
        body = bytearray(12)
        offsets = []
        for allocation in self.allocations:
            offsets.append(len(body))
            body += allocation
        offsets.append(len(body))
        if len(body) % 2:
            body += b"\0"
        page_map = len(body)
        body += struct.pack("<HH", len(self.allocations), 0) + b"".join(struct.pack("<H", o) for o in offsets)
        struct.pack_into("<HBBI", body, 0, page_map, 0xEC, self.client_signature, user_root)
        assert len(body) <= MAX_BLOCK, len(body)
        return bytes(body)


def bth(heap, key_size, data_size, records):
    records = sorted(records, key=lambda r: int.from_bytes(r[0], "little"))
    leaf = b"".join(key + data for key, data in records)
    assert len(leaf) <= MAX_ALLOCATION
    root = heap.alloc(leaf) if records else 0
    return heap.alloc(struct.pack("<BBBBI", 0xB5, key_size, data_size, 0, root))


class PSTWriter:
    def __init__(self, unicode=True):
        self.unicode = unicode
        self.id = "Q" if unicode else "I"
        self.max_block = MAX_BLOCK if unicode else 8180
        self.blocks = []  # (bid, stored bytes)
        self.nodes = {}  # nid -> (bidData, bidSub, nidParent)
        self.block_counter = 1
        self.ltp_counter = 0x400

    def block(self, data, internal=False):
        assert len(data) <= self.max_block
        bid = self.block_counter * 4 + (2 if internal else 0)
        self.block_counter += 1
        self.blocks.append((bid, bytes(data) if internal else bytes(PERMUTE[b] for b in data)))
        return bid

    def data(self, data):
        """A data tree: one block, or an XBLOCK of blocks"""
        if len(data) <= self.max_block:
            return self.block(data)
        step = self.max_block
        bids = [self.block(data[i:i + step]) for i in range(0, len(data), step)]
        return self.block(struct.pack("<BBHI", 1, 1, len(bids), len(data))
                          + b"".join(struct.pack("<" + self.id, b) for b in bids), internal=True)

    def subnodes(self, entries):
        """entries: nid -> (bidData, bidSub)"""
        if not entries:
            return 0
        rows = sorted(entries.items())
        header = struct.pack("<BBHI", 2, 0, len(rows), 0) if self.unicode else struct.pack("<BBH", 2, 0, len(rows))
        return self.block(header + b"".join(struct.pack("<" + self.id * 3, nid, data, sub) for nid, (data, sub) in rows),
                          internal=True)

    def ltp_nid(self):
        self.ltp_counter += 1
        return self.ltp_counter << 5 | TYPE_LTP

    def hnid(self, heap, raw, subnodes):
        if len(raw) <= MAX_ALLOCATION:
            return heap.alloc(raw)
        nid = self.ltp_nid()
        subnodes[nid] = (self.data(raw), 0)
        return nid

    def property_context(self, properties, subnodes):
        """properties: (id, type, value); an object is (nid, size). Large values go to subnodes."""
        heap = Heap(0xBC)
        records = []
        for pid, ptype, value in properties:
            if ptype in (PT_INT32, PT_BOOLEAN):
                cell = value if ptype == PT_INT32 else (1 if value else 0)
            elif ptype == PT_OBJECT:
                cell = heap.alloc(struct.pack("<II", *value))
            else:
                cell = self.hnid(heap, encode_value(ptype, value), subnodes)
            records.append((struct.pack("<H", pid), struct.pack("<HI", ptype, cell)))
        return heap.build(bth(heap, 2, 6, records))

    def table_context(self, columns, rows, subnodes):
        """columns: (id, type); rows: (row id, {id: value})"""
        heap = Heap(0x7C)

        def size(ptype):
            return {PT_BOOLEAN: 1, PT_INT64: 8, PT_TIME: 8}.get(ptype, 4)

        ordered = [(0x67F2, PT_INT32), (0x67F3, PT_INT32)] + sorted(columns, key=lambda c: -size(c[1]))
        layout = {}
        offset = 0
        for bit, (pid, ptype) in enumerate(ordered):
            layout[pid] = (offset, size(ptype), bit, ptype)
            offset += size(ptype)
        end4 = sum(size(t) for _, t in ordered if size(t) >= 4)
        end2 = end4 + sum(size(t) for _, t in ordered if size(t) == 2)
        end1 = end2 + sum(size(t) for _, t in ordered if size(t) == 1)
        row_size = end1 + (len(ordered) + 7) // 8

        matrix = bytearray()
        index = []
        for number, (row_id, values) in enumerate(rows):
            row = bytearray(row_size)
            values = dict(values)
            values[0x67F2] = row_id
            values[0x67F3] = 1
            for pid, value in values.items():
                offset, cell_size, bit, ptype = layout[pid]
                if ptype == PT_INT32:
                    cell = struct.pack("<I", value)
                elif ptype == PT_BOOLEAN:
                    cell = bytes([1 if value else 0])
                elif ptype in (PT_INT64, PT_TIME):
                    cell = struct.pack("<Q", value)
                else:
                    cell = struct.pack("<I", self.hnid(heap, encode_value(ptype, value), subnodes))
                row[offset:offset + cell_size] = cell
                row[end1 + bit // 8] |= 0x80 >> (bit % 8)
            matrix += row
            index.append((struct.pack("<I", row_id), struct.pack("<I" if self.unicode else "<H", number)))
        rows_hnid = self.hnid(heap, bytes(matrix), subnodes) if rows else 0
        row_index = bth(heap, 4, 4 if self.unicode else 2, index)
        descriptors = sorted(((pid << 16 | ptype), offset, cell_size, bit)
                             for pid, (offset, cell_size, bit, ptype) in layout.items())
        info = struct.pack("<BB4HIII", 0x7C, len(ordered), end4, end2, end1, row_size, row_index, rows_hnid, 0)
        info += b"".join(struct.pack("<IHBB", *d) for d in descriptors)
        return heap.build(heap.alloc(info))

    def node(self, nid, parent, data, subnodes=None):
        self.nodes[nid] = (self.data(data), self.subnodes(subnodes or {}), parent)

    # Messaging layer

    def folder(self, nid, parent, name, children, messages):
        """children: (nid, name, has subfolders); messages: (nid, subject, time)"""
        index = nid >> 5
        # A name given as bytes is 8-bit text, as ANSI files hold it
        text = PT_STRING8 if isinstance(name, bytes) else PT_STRING
        self.node(nid, parent, self.property_context([
            (0x3001, text, name), (0x3602, PT_INT32, len(messages)), (0x3603, PT_INT32, 0),
            (0x360A, PT_BOOLEAN, bool(children)), (0x3613, PT_STRING, "IPF.Note"),
        ], {}))
        subnodes = {}
        names = {PT_STRING8 if isinstance(child_name, bytes) else PT_STRING for _, child_name, _ in children} or {PT_STRING}
        hierarchy = self.table_context(
            [(0x3001, names.pop()), (0x3602, PT_INT32), (0x3603, PT_INT32), (0x360A, PT_BOOLEAN)],
            [(child, {0x3001: child_name, 0x3602: 0, 0x3603: 0, 0x360A: sub}) for child, child_name, sub in children],
            subnodes)
        self.node(index << 5 | TYPE_HIERARCHY, 0, hierarchy, subnodes)
        subnodes = {}
        contents = self.table_context(
            [(0x0037, PT_STRING), (0x0E06, PT_TIME), (0x0E07, PT_INT32)],
            [(message, {0x0037: subject, 0x0E06: when, 0x0E07: 1}) for message, subject, when in messages],
            subnodes)
        self.node(index << 5 | TYPE_CONTENTS, 0, contents, subnodes)
        self.node(index << 5 | TYPE_ASSOC, 0, self.table_context([(0x0037, PT_STRING)], [], {}))

    def message_nodes(self, properties, recipients, attachments):
        """Returns the message's PC and its subnode entries. attachments: ("file", name, bytes) or
        ("message", name, (properties, recipients, attachments))."""
        subnodes = {}
        subnodes[NID_RECIPIENT_TABLE] = (self.data(self.table_context(
            [(0x0C15, PT_INT32), (0x3001, PT_STRING), (0x3003, PT_STRING), (0x3002, PT_STRING), (0x39FE, PT_STRING)],
            [(n, {0x0C15: kind, 0x3001: name, 0x3003: email, 0x3002: "SMTP", 0x39FE: email})
             for n, (name, email, kind) in enumerate(recipients)], subnodes)), 0)
        rows = []
        for n, (kind, name, payload) in enumerate(attachments):
            nid = (0x8000 + n) << 5 | TYPE_ATTACHMENT
            own = {}
            props = [(0x3707, PT_STRING, name), (0x3704, PT_STRING, name), (0x3001, PT_STRING, name),
                     (0x370B, PT_INT32, 0xFFFFFFFF)]
            if kind == "file":
                props += [(0x3705, PT_INT32, 1), (0x3701, PT_BINARY, payload), (0x0E20, PT_INT32, len(payload))]
                size = len(payload)
            else:
                embedded_nid = self.ltp_nid()
                pc, embedded_subnodes = self.message_nodes(*payload)
                own[embedded_nid] = (self.data(pc), self.subnodes(embedded_subnodes))
                size = len(pc)
                props += [(0x3705, PT_INT32, 5), (0x3701, PT_OBJECT, (embedded_nid, size)), (0x0E20, PT_INT32, size)]
            pc = self.property_context(sorted(props), own)
            subnodes[nid] = (self.data(pc), self.subnodes(own))
            rows.append((nid, {0x0E20: size, 0x3707: name, 0x3705: 1 if kind == "file" else 5, 0x370B: 0xFFFFFFFF}))
        if attachments:
            subnodes[NID_ATTACHMENT_TABLE] = (self.data(self.table_context(
                [(0x0E20, PT_INT32), (0x3707, PT_STRING), (0x3705, PT_INT32), (0x370B, PT_INT32)], rows, subnodes)), 0)
        properties = dict(((pid, ptype), value) for pid, ptype, value in properties)
        properties[(0x0E07, PT_INT32)] = 0x01 | (0x10 if attachments else 0)
        properties[(0x0E1B, PT_BOOLEAN)] = bool(attachments)
        pc = self.property_context(sorted((pid, ptype, value) for (pid, ptype), value in properties.items()), subnodes)
        return pc, subnodes

    def message(self, nid, folder, properties, recipients, attachments):
        pc, subnodes = self.message_nodes(properties, recipients, attachments)
        self.nodes[nid] = (self.data(pc), self.subnodes(subnodes), folder)

    def store(self, name, subtree, wastebasket):
        uid = bytes(range(0x10, 0x20))
        entry = lambda nid: struct.pack("<I", 0) + uid + struct.pack("<I", nid)
        self.node(NID_MESSAGE_STORE, 0, self.property_context([
            (0x0FF9, PT_BINARY, uid), (0x3001, PT_STRING, name), (0x35DF, PT_INT32, 0x89),
            (0x35E0, PT_BINARY, entry(subtree)), (0x35E3, PT_BINARY, entry(wastebasket)),
            (0x67FF, PT_INT32, 0),
        ], {}))
        # Named properties: one numeric property in PSETID_Common, as readers expect some
        common = bytes.fromhex("0820060000000000c000000000000046")
        self.node(NID_NAME_TO_ID_MAP, 0, self.property_context([
            (0x0001, PT_INT32, 251), (0x0002, PT_BINARY, common),
            (0x0003, PT_BINARY, struct.pack("<IHH", 0x8501, 3 << 1, 0)), (0x0004, PT_BINARY, b"\0\0\0\0"),
        ], {}))

    # The file

    def write(self):
        unicode = self.unicode
        trailer = 16 if unicode else 12
        entries_area = 488 if unicode else 496
        AMAP = 0x4400
        out = bytearray(AMAP + 1024)  # header, then the first AMap and PMap pages
        used = []  # (offset, length) inside the AMap's range

        bbt = []
        for bid, stored in self.blocks:
            ib = len(out)
            total = align(len(stored) + trailer, 64)
            block = bytearray(total)
            block[:len(stored)] = stored
            if unicode:
                struct.pack_into("<HHIQ", block, total - 16, len(stored), signature(ib, bid), pst_crc(stored), bid)
            else:
                struct.pack_into("<HHII", block, total - 12, len(stored), signature(ib, bid), bid, pst_crc(stored))
            out += block
            used.append((ib, total))
            bbt.append((bid, ib, len(stored)))
        out += bytes(align(len(out), 512) - len(out))

        page_counter = [0x40]

        def page(entries, entry_size, level, ptype):
            bid = page_counter[0]
            page_counter[0] += 1
            ib = len(out)
            body = bytearray(512)
            data = b"".join(entries)
            body[:len(data)] = data
            struct.pack_into("<BBBB", body, entries_area, len(entries), entries_area // entry_size, entry_size, level)
            if unicode:
                struct.pack_into("<BBH", body, 496, ptype, ptype, signature(ib, bid))
                struct.pack_into("<IQ", body, 500, pst_crc(bytes(body[:496])), bid)
            else:
                struct.pack_into("<BBHII", body, 500, ptype, ptype, signature(ib, bid), bid, pst_crc(bytes(body[:500])))
            out.extend(body)
            used.append((ib, 512))
            return bid, ib

        def tree(leaves, entry_size, ptype):
            """leaves: (key, packed entry), sorted. Returns the root's (bid, ib)."""
            level = 0
            items = leaves
            branch_size = 24 if unicode else 12
            while True:
                size = entry_size if level == 0 else branch_size
                pages = []
                for start in range(0, len(items), entries_area // size):
                    chunk = items[start:start + entries_area // size]
                    bid, ib = page([e for _, e in chunk], size, level, ptype)
                    pages.append((chunk[0][0], struct.pack("<" + self.id * 3, chunk[0][0], bid, ib)))
                if len(pages) == 1:
                    return bid, ib
                items = pages
                level += 1

        i = self.id
        bbt_root = tree([(bid, struct.pack("<" + i * 2 + "HH" + ("I" if unicode else ""), bid, ib, cb, 2, *([0] if unicode else [])))
                         for bid, ib, cb in sorted(bbt)], 24 if unicode else 12, 0x80)
        nbt_root = tree([(nid, struct.pack("<" + i * 3 + "I" + ("I" if unicode else ""), nid, data, sub, parent, *([0] if unicode else [])))
                         for nid, (data, sub, parent) in sorted(self.nodes.items())], 32 if unicode else 16, 0x81)

        # Allocation map: one bit per 64 bytes from the AMap page on, the first byte's high bit first
        bits_size = 496 if unicode else 500
        used += [(AMAP, 512), (AMAP + 512, 512)]
        bits = bytearray(bits_size)
        for ib, length in used:
            for unit in range((ib - AMAP) // 64, (ib - AMAP + length) // 64):
                bits[unit // 8] |= 0x80 >> (unit % 8)
        assert len(out) - AMAP <= bits_size * 8 * 64
        free = (bits_size * 8 - sum(bin(b).count("1") for b in bits)) * 64
        for offset, ptype, fill in ((AMAP, 0x84, bytes(bits)), (AMAP + 512, 0x83, b"\xff" * bits_size)):
            map_page = bytearray(512)
            map_page[:bits_size] = fill
            if unicode:
                struct.pack_into("<BBHIQ", map_page, 496, ptype, ptype, 0, pst_crc(fill), offset)
            else:
                struct.pack_into("<BBHII", map_page, 500, ptype, ptype, 0, offset, pst_crc(fill))
            out[offset:offset + 512] = map_page

        header = bytearray(564 if unicode else 512)
        header[0:4] = b"!BDN"
        struct.pack_into("<HHHBB", header, 8, 0x4D53, 23 if unicode else 14, 19, 1, 1)
        if unicode:
            struct.pack_into("<QQI", header, 24, 0, page_counter[0], 0x2468)
            nids = 44
            struct.pack_into("<IQQQQQQQQBBH", header, 180, 0, len(out), AMAP, free, 0,
                             nbt_root[0], nbt_root[1], bbt_root[0], bbt_root[1], 2, 0, 0)
            header[256:512] = b"\xff" * 256
            struct.pack_into("<BBH", header, 512, 0x80, 1, 0)
            struct.pack_into("<Q", header, 516, self.block_counter * 4)
        else:
            struct.pack_into("<III", header, 24, self.block_counter * 4, page_counter[0], 0x2468)
            nids = 36
            struct.pack_into("<IIIIIIIIIBBH", header, 164, 0, len(out), AMAP, free, 0,
                             nbt_root[0], nbt_root[1], bbt_root[0], bbt_root[1], 2, 0, 0)
            header[204:460] = b"\xff" * 256
            struct.pack_into("<BB", header, 460, 0x80, 1)
        for n in range(32):
            struct.pack_into("<I", header, nids + n * 4, 0x2000)
        struct.pack_into("<I", header, 4, pst_crc(bytes(header[8:8 + 471])))
        if unicode:
            struct.pack_into("<I", header, 524, pst_crc(bytes(header[8:8 + 516])))
        out[0:len(header)] = header
        return bytes(out)
