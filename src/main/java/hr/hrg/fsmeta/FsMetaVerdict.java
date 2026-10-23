// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.util.Optional;

/**
 * The outcome of validating a pair, {@code FORMAT.md} § 8's fixed vocabulary.
 *
 * <p>These strings are a contract across implementations, not a message: the Java and Bun validators
 * report the same wire name for the same bytes, and the shared vectors assert them case by case. A
 * message for a human is {@link FsMetaValidation#detail()}'s job.</p>
 */
public enum FsMetaVerdict {

    /** The pair is usable. Entries may still be individually untrusted (§ 6). */
    OK("ok"),

    /** {@code files.json} is not an fs-meta document this reader understands (§ 8, checks 1–2). */
    UNSUPPORTED_FORMAT("unsupported-format"),

    /** The document's {@code version} is not implemented (§ 8, check 3). */
    UNSUPPORTED_VERSION("unsupported-version"),

    /** The document's {@code entrySize} is not this version's 64 (§ 8, check 4). */
    UNSUPPORTED_ENTRY_SIZE("unsupported-entry-size"),

    /**
     * The document's hash is not this version's {@code wyhash64} with seed 0 (§ 8, check 5). The entries'
     * 64-bit values are comparable between tools only if they mean the same algorithm, so a document that
     * names another one is not a v1 document this reader can use.
     */
    UNSUPPORTED_HASH("unsupported-hash"),

    /** The meta file's size disagrees with itself, the count, or the document (§ 8, check 6). */
    META_SIZE_MISMATCH("meta-size-mismatch"),

    /**
     * The meta file's whole-file hash disagrees with the document's {@code meta.wyhash} (§ 8, check 6b).
     * A size that agrees is not a claim about the bytes; this is.
     */
    META_HASH_MISMATCH("meta-hash-mismatch"),

    /** The text file's size disagrees with the document, or its line structure with the count (check 7). */
    TXT_SIZE_MISMATCH("txt-size-mismatch"),

    /** The text file's whole-file hash disagrees with the document's {@code txt.wyhash} (check 7b). */
    TXT_HASH_MISMATCH("txt-hash-mismatch"),

    /** An entry's name slice falls outside {@code files.txt}, is empty, or is not LF-terminated (check 8). */
    ENTRY_OUT_OF_RANGE("entry-out-of-range"),

    /** The name at an entry's offset does not hash to the entry's {@code nameHash} (check 9). */
    NAME_HASH_MISMATCH("name-hash-mismatch"),

    /**
     * An entry's flags do not set exactly one type bit, carry a bit this version does not define, or set
     * {@code HASH_LF} without {@code CONTENT_KNOWN} (§ 6, § 8 check 10).
     */
    INVALID_FLAGS("invalid-flags");

    private final String wire;

    FsMetaVerdict(String wire) {
        this.wire = wire;
    }

    /** The string the vectors and every implementation use. */
    public String wire() {
        return wire;
    }

    /** The verdict a wire name denotes, if this version defines it. */
    public static Optional<FsMetaVerdict> fromWire(String wire) {
        for (FsMetaVerdict verdict : values()) {
            if (verdict.wire.equals(wire)) {
                return Optional.of(verdict);
            }
        }
        return Optional.empty();
    }

    /** Whether the pair is usable at all: only {@link #OK} is. */
    public boolean usable() {
        return this == OK;
    }

    @Override
    public String toString() {
        return wire;
    }
}
