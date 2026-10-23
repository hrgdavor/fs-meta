// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.nio.charset.StandardCharsets;
import java.util.Comparator;

/**
 * The format's constants and its two pieces of arithmetic: the entry layout and the name order.
 *
 * <p>{@code FORMAT.md} is the normative specification; every constant here is one of its tables, and
 * {@code FsMetaConformanceTest} asserts the byte layout against the shared vectors rather than against
 * this file's own arithmetic.</p>
 */
public final class FsMetaFormat {

    /** The {@code format} value of the sidekick document. A reader rejects anything else (§ 8, check 2). */
    public static final String FORMAT = "fs-meta";

    /** The version this implementation reads and writes. An unknown version is rejected (§ 8, check 3). */
    public static final int VERSION = 1;

    /**
     * 64: a power of two, so {@code entry(i)} is {@code i << 6} and the count is a shift — and so one
     * entry is one cache line, which is what a sequential scan of {@code files.meta} mostly touches.
     */
    public static final int ENTRY_SIZE = 64;

    /** The directory the trio lives in, relative to the root it describes. */
    public static final String DIRECTORY_NAME = ".fs-meta";

    public static final String META_FILE = "files.meta";
    public static final String TXT_FILE = "files.txt";
    public static final String JSON_FILE = "files.json";

    /** The name-ordering rule's wire name (§ 3): unsigned byte comparison of the UTF-8 encoding. */
    public static final String ORDER = "utf8-bytes";

    /** The hash algorithm's wire name: {@code hr.hrg.wyhash:wyhash:1.0.0} / Zig {@code std.hash.Wyhash}. */
    public static final String HASH_ALGO = "wyhash64";

    /** Every hash in the format is taken with seed 0 (§ 12). */
    public static final long HASH_SEED = 0L;

    /** The separator of {@code files.txt}: LF, after every name including the last (§ 4). */
    public static final byte LF = 0x0A;

    // ---- entry field offsets, § 5 ------------------------------------------

    public static final int OFFSET_MTIME_MILLIS = 0;
    public static final int OFFSET_NAME_HASH = 8;
    public static final int OFFSET_CONTENT_HASH = 16;
    public static final int OFFSET_SIZE_BYTES = 24;
    public static final int OFFSET_NAME_OFFSET = 32;
    public static final int OFFSET_NAME_LENGTH = 40;
    public static final int OFFSET_FLAGS = 44;
    public static final int OFFSET_FILE_ID = 48;
    public static final int OFFSET_RESERVED = 56;

    // ---- entry flags, § 6 --------------------------------------------------

    /** {@code mtimeMillis}, {@code contentHash} and {@code sizeBytes} are all valid. */
    public static final int FLAG_CONTENT_KNOWN = 0x01;

    /** The entry describes a regular file. */
    public static final int FLAG_REGULAR_FILE = 0x02;

    /** The content hash was taken over LF-normalised content rather than over the raw bytes. */
    public static final int FLAG_HASH_LF = 0x04;

    /** The bits this version defines; anything else makes an entry untrusted (§ 6). */
    public static final int FLAG_KNOWN_MASK = FLAG_CONTENT_KNOWN | FLAG_REGULAR_FILE | FLAG_HASH_LF;

    /**
     * The writer's name order (§ 3): unsigned byte comparison of the UTF-8 encoding.
     *
     * <p>Deliberately not {@link String#compareTo}: that compares UTF-16 code units, which orders some
     * non-BMP characters differently from the bytes the format stores, and the difference would show up
     * as a pair that a byte-wise reader considers unsorted.</p>
     */
    public static final Comparator<String> NAME_ORDER = FsMetaFormat::compareNames;

    private FsMetaFormat() {
    }

    /** Compares two names by their UTF-8 bytes, unsigned, exactly as {@code memcmp} would (§ 3). */
    public static int compareNames(String left, String right) {
        return compareUtf8(left.getBytes(StandardCharsets.UTF_8), right.getBytes(StandardCharsets.UTF_8));
    }

    /** Compares two UTF-8 byte sequences unsigned, the way {@code files.txt} is ordered. */
    public static int compareUtf8(byte[] left, byte[] right) {
        int shared = Math.min(left.length, right.length);
        for (int i = 0; i < shared; i++) {
            int difference = (left[i] & 0xFF) - (right[i] & 0xFF);
            if (difference != 0) {
                return difference;
            }
        }
        return left.length - right.length;
    }

    /**
     * The entry count of a {@code files.meta} of {@code metaBytes} bytes: a shift, not a division.
     *
     * @throws IllegalArgumentException when the size is not a whole number of entries, which is a
     *                                  validation failure rather than something to round
     */
    public static long entryCount(long metaBytes) {
        if (metaBytes < 0 || (metaBytes & (ENTRY_SIZE - 1)) != 0) {
            throw new IllegalArgumentException(
                    "files.meta is " + metaBytes + " bytes, which is not a whole number of "
                            + ENTRY_SIZE + "-byte entries");
        }
        return metaBytes >>> 6;
    }

    /** The byte offset of entry {@code index}: {@code index << 6}. */
    public static long entryOffset(long index) {
        if (index < 0) {
            throw new IllegalArgumentException("entry index is negative: " + index);
        }
        return index << 6;
    }

    /** Whether a flags word carries a bit this version does not define — the entry is then untrusted. */
    public static boolean hasUnknownFlags(int flags) {
        return (flags & ~FLAG_KNOWN_MASK) != 0;
    }

    /** The flags word a hashed regular file gets. */
    public static int fileFlags(boolean hashLf) {
        return FLAG_CONTENT_KNOWN | FLAG_REGULAR_FILE | (hashLf ? FLAG_HASH_LF : 0);
    }

    /** The flags word a listing-only entry gets: the file is known, no fingerprint was taken (§ 6). */
    public static int listingOnlyFlags() {
        return FLAG_REGULAR_FILE;
    }
}
