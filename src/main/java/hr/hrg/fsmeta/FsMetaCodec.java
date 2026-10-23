// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;

/**
 * The entry codec: {@code FORMAT.md} § 5's 64-byte record, little-endian, and {@code files.txt} (§ 4).
 *
 * <p>This is the only place in the Java implementation that knows a field's offset. Everything else works
 * in {@link FsMetaEntry} values, which is what keeps a layout change a change in two files (this one and
 * the vectors) rather than a hunt through the code.</p>
 */
public final class FsMetaCodec {

    private FsMetaCodec() {
    }

    /**
     * The 64 bytes of one entry at {@code entryOffset} in {@code target}, in the field order § 5 publishes.
     *
     * <p>Absolute puts, deliberately: a caller may be filling a buffer entry by entry or rewriting one
     * entry of a pair already in memory, and a relative write would turn the second case into a position
     * bookkeeping question.</p>
     */
    public static void putEntry(ByteBuffer target, long entryOffset, FsMetaEntry entry) {
        int at = Math.toIntExact(entryOffset);
        target.putLong(at + FsMetaFormat.OFFSET_MTIME_NS, entry.mtimeNs());
        target.putLong(at + FsMetaFormat.OFFSET_SIZE_BYTES, entry.sizeBytes());
        target.putLong(at + FsMetaFormat.OFFSET_CONTENT_HASH, entry.contentHash());
        target.putLong(at + FsMetaFormat.OFFSET_NAME_HASH, entry.nameHash());
        target.putLong(at + FsMetaFormat.OFFSET_NAME_OFFSET, entry.nameOffset());
        target.putInt(at + FsMetaFormat.OFFSET_NAME_LENGTH, entry.nameLength());
        target.putInt(at + FsMetaFormat.OFFSET_FLAGS, entry.flags());
        target.putLong(at + FsMetaFormat.OFFSET_FILE_ID_LO, entry.fileIdLo());
        target.putLong(at + FsMetaFormat.OFFSET_FILE_ID_HI, entry.fileIdHi());
    }

    /** One entry read from {@code source} at {@code offset} — the caller owns the 64-byte bound. */
    public static FsMetaEntry getEntry(ByteBuffer source, long offset) {
        int at = Math.toIntExact(offset);
        return new FsMetaEntry(
                source.getLong(at + FsMetaFormat.OFFSET_MTIME_NS),
                source.getLong(at + FsMetaFormat.OFFSET_SIZE_BYTES),
                source.getLong(at + FsMetaFormat.OFFSET_CONTENT_HASH),
                source.getLong(at + FsMetaFormat.OFFSET_NAME_HASH),
                source.getLong(at + FsMetaFormat.OFFSET_NAME_OFFSET),
                source.getInt(at + FsMetaFormat.OFFSET_NAME_LENGTH),
                source.getInt(at + FsMetaFormat.OFFSET_FLAGS),
                source.getLong(at + FsMetaFormat.OFFSET_FILE_ID_LO),
                source.getLong(at + FsMetaFormat.OFFSET_FILE_ID_HI));
    }

    /** The whole {@code files.meta} for {@code entries}, in the order given. */
    public static byte[] encodeEntries(List<FsMetaEntry> entries) {
        ByteBuffer buffer = ByteBuffer.allocate(entries.size() * FsMetaFormat.ENTRY_SIZE)
                .order(ByteOrder.LITTLE_ENDIAN);
        for (int index = 0; index < entries.size(); index++) {
            putEntry(buffer, FsMetaFormat.entryOffset(index), entries.get(index));
        }
        return buffer.array();
    }

    /**
     * The entries of a {@code files.meta}.
     *
     * @throws IllegalArgumentException when the size is not a whole number of entries — the validator
     *                                  reaches its own verdict before calling this
     */
    public static List<FsMetaEntry> decodeEntries(byte[] meta) {
        long count = FsMetaFormat.entryCount(meta.length);
        ByteBuffer buffer = ByteBuffer.wrap(meta).order(ByteOrder.LITTLE_ENDIAN);
        List<FsMetaEntry> entries = new ArrayList<>(Math.toIntExact(count));
        for (long i = 0; i < count; i++) {
            entries.add(getEntry(buffer, FsMetaFormat.entryOffset(i)));
        }
        return entries;
    }

    /** {@code files.txt} for {@code names}: every name followed by LF, including the last (§ 4). */
    public static byte[] encodeNames(List<String> names) {
        int bytes = 0;
        for (String name : names) {
            bytes += utf8Length(name) + 1;
        }
        byte[] text = new byte[bytes];
        int at = 0;
        for (String name : names) {
            byte[] encoded = name.getBytes(java.nio.charset.StandardCharsets.UTF_8);
            System.arraycopy(encoded, 0, text, at, encoded.length);
            at += encoded.length;
            text[at++] = FsMetaFormat.LF;
        }
        return text;
    }

    /** The UTF-8 byte length of a name, which is its {@code nameLength} in the entry. */
    public static int utf8Length(String name) {
        return name.getBytes(java.nio.charset.StandardCharsets.UTF_8).length;
    }
}
