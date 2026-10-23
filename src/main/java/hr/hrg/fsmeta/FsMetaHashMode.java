// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.util.Optional;

/**
 * How a writer hashes content, the {@code hash.normalize} value of {@code files.json} (§ 7, § 12).
 *
 * <p>The mode is the writer's <em>default</em>; the per-entry {@code HASH_LF} flag is authoritative, which
 * is what lets one tree hold normalised sources and raw images at the same time.</p>
 */
public enum FsMetaHashMode {

    /** Hash the bytes exactly as they are on disk. */
    NONE("none"),

    /** Normalise {@code \r\n} and a lone {@code \r} to {@code \n} before hashing, for every file. */
    LF("lf"),

    /**
     * Decide per file: normalise a file that looks like text (no NUL byte) and hash a binary one raw,
     * recording the decision in the entry's {@code HASH_LF} flag. This is the mode that makes a CRLF and
     * an LF checkout of the same tree agree while leaving images and archives alone.
     */
    TEXT("text");

    private final String wire;

    FsMetaHashMode(String wire) {
        this.wire = wire;
    }

    /** The string the sidekick document carries. */
    public String wire() {
        return wire;
    }

    /** The mode a wire name denotes, empty when this version does not define it. */
    public static Optional<FsMetaHashMode> fromWire(String wire) {
        if (wire == null) {
            return Optional.empty();
        }
        for (FsMetaHashMode mode : values()) {
            if (mode.wire.equals(wire)) {
                return Optional.of(mode);
            }
        }
        return Optional.empty();
    }

    @Override
    public String toString() {
        return wire;
    }
}
