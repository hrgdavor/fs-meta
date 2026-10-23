// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

/**
 * One {@code files.meta} entry — {@code FORMAT.md} § 5's nine fields, in a value.
 *
 * <p>The record keeps the reserved words ({@code fileId}, {@code reserved}) because a reader that rewrites
 * a pair must not silently drop what a later version wrote there; § 5 says a v1 reader ignores them, and
 * ignoring is not the same as discarding.</p>
 */
public record FsMetaEntry(
        long mtimeMillis,
        long nameHash,
        long contentHash,
        long sizeBytes,
        long nameOffset,
        int nameLength,
        int flags,
        long fileId,
        long reserved) {

    /** A hashed regular file: every fingerprint field is valid. */
    public static FsMetaEntry forFile(
            String name, long mtimeMillis, long sizeBytes, long contentHash, long nameOffset, boolean hashLf) {
        return new FsMetaEntry(
                mtimeMillis,
                FsMetaHash.ofName(name),
                contentHash,
                sizeBytes,
                nameOffset,
                FsMetaCodec.utf8Length(name),
                FsMetaFormat.fileFlags(hashLf),
                0L,
                0L);
    }

    /**
     * A listing-only entry (§ 6): the name is known, no fingerprint was taken, and the three fingerprint
     * fields are zero and must be ignored.
     */
    public static FsMetaEntry listingOnly(String name, long nameOffset) {
        return new FsMetaEntry(
                0L,
                FsMetaHash.ofName(name),
                0L,
                0L,
                nameOffset,
                FsMetaCodec.utf8Length(name),
                FsMetaFormat.listingOnlyFlags(),
                0L,
                0L);
    }

    /** § 6: {@code mtimeMillis}, {@code contentHash} and {@code sizeBytes} are all valid. */
    public boolean contentKnown() {
        return (flags & FsMetaFormat.FLAG_CONTENT_KNOWN) != 0;
    }

    /** § 6: the entry describes a regular file. */
    public boolean regularFile() {
        return (flags & FsMetaFormat.FLAG_REGULAR_FILE) != 0;
    }

    /** § 12: the content hash was taken over LF-normalised content. */
    public boolean hashLf() {
        return (flags & FsMetaFormat.FLAG_HASH_LF) != 0;
    }

    /**
     * § 6: whether the entry may be used at all. A reserved bit means a later version gave it a meaning
     * this reader does not know, so the fingerprint is not to be trusted.
     */
    public boolean trusted() {
        return !FsMetaFormat.hasUnknownFlags(flags);
    }

    /** Whether there is a fingerprint to compare: trusted <em>and</em> content-known (§ 11, step 2). */
    public boolean usableFingerprint() {
        return trusted() && contentKnown();
    }

    /** The remaining reserved bits, so a caller can report *why* an entry is untrusted. */
    public int unknownFlagBits() {
        return flags & ~FsMetaFormat.FLAG_KNOWN_MASK;
    }

    /** One line, the shape {@code fsmeta query} and {@code fsmeta dump} print. */
    public String format(String name) {
        return name + "\t"
                + mtimeMillis + "\t"
                + sizeBytes + "\t"
                + String.format("%016x", contentHash) + "\t"
                + String.format("%016x", nameHash) + "\t"
                + flags;
    }
}
