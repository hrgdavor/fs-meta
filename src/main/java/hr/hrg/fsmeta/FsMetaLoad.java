// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.util.List;

/**
 * The result of reading a trio from disk: the verdict, and a usable {@link FsMetaPair} only when the
 * verdict is {@link FsMetaVerdict#OK}.
 *
 * <p>The two are separate types on purpose. A caller cannot reach an entry's fields through a failed load
 * — the only thing it can do with a failure is fall back to the file system, which is what § 1 asks of it.
 * {@link #directory()} is carried so a diagnostic can name the trio it rejected.</p>
 *
 * @param directory the directory the trio was read from
 * @param verdict   what validation decided
 * @param config    the parsed document, or {@code null} when it could not be parsed at all
 * @param pair      the usable pair, or {@code null} when the verdict is not {@code ok}
 * @param detail    one sentence for a human, empty when the load succeeded
 */
public record FsMetaLoad(
        java.nio.file.Path directory,
        FsMetaVerdict verdict,
        FsMetaConfig config,
        FsMetaPair pair,
        String detail) {

    /** Whether the trio is usable. */
    public boolean ok() {
        return verdict.usable();
    }

    /** One line for a log or a terminal, naming the directory it is about. */
    public String describe() {
        String where = directory == null ? "the trio" : directory.toString();
        return ok() ? where + ": " + pair.validation().describe()
                : where + ": " + verdict.wire() + (detail.isEmpty() ? "" : " — " + detail);
    }

    /** The entries, or an empty list when the load failed — the shape a caller that only iterates wants. */
    public List<FsMetaEntry> entriesOrEmpty() {
        return pair == null ? List.of() : pair.entries();
    }
}
