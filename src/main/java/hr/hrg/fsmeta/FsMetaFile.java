// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

/**
 * One file as a scan found it: the name plus the fingerprint fields an entry is built from.
 *
 * <p>This is the writer's input and the reader's output in the same shape, which is what makes
 * "scan, publish" and "read, publish" the same two calls. The entry's {@code nameOffset}, {@code fileId}
 * and {@code reserved} are not here: the offset is a property of where the name lands in
 * {@code files.txt}, and the two reserved words belong to the entry (§ 5).</p>
 */
public record FsMetaFile(
        String name,
        long mtimeMillis,
        long sizeBytes,
        long contentHash,
        int flags) {

    /** A file whose content was read and hashed. */
    public static FsMetaFile hashed(
            String name, long mtimeMillis, long sizeBytes, long contentHash, boolean hashLf) {
        return new FsMetaFile(name, mtimeMillis, sizeBytes, contentHash, FsMetaFormat.fileFlags(hashLf));
    }

    /** A file the writer listed without reading — no fingerprint, and the three fields are ignored (§ 6). */
    public static FsMetaFile listingOnly(String name) {
        return new FsMetaFile(name, 0L, 0L, 0L, FsMetaFormat.listingOnlyFlags());
    }

    /** § 6: whether {@code mtimeMillis}, {@code sizeBytes} and {@code contentHash} mean anything. */
    public boolean contentKnown() {
        return (flags & FsMetaFormat.FLAG_CONTENT_KNOWN) != 0;
    }

    /** The entry this file becomes once its name's place in {@code files.txt} is known. */
    public FsMetaEntry toEntry(long nameOffset) {
        return new FsMetaEntry(
                mtimeMillis,
                FsMetaHash.ofName(name),
                contentHash,
                sizeBytes,
                nameOffset,
                FsMetaCodec.utf8Length(name),
                flags & FsMetaFormat.FLAG_KNOWN_MASK,
                0L,
                0L);
    }
}
