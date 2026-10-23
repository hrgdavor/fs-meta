// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.util.List;

/**
 * What validating a pair produced: {@code FORMAT.md} § 8's verdict, the first entry that failed, and the
 * entries a reader must not trust even when the pair is usable.
 *
 * @param verdict       the wire verdict; only {@link FsMetaVerdict#OK} is usable
 * @param firstBadEntry the 0-based index of the first entry a check rejected, or {@code -1}
 * @param untrusted     indices of entries with a flag bit this version does not define (§ 6), ascending;
 *                      empty when the verdict is not {@link FsMetaVerdict#OK}
 * @param detail        one sentence for a human, never empty on a failure
 */
public record FsMetaValidation(
        FsMetaVerdict verdict,
        int firstBadEntry,
        List<Integer> untrusted,
        String detail) {

    /** A usable pair with no untrusted entries. */
    public static FsMetaValidation ok() {
        return new FsMetaValidation(FsMetaVerdict.OK, -1, List.of(), "");
    }

    /** A usable pair that carries entries a reader must read for itself. */
    public static FsMetaValidation ok(List<Integer> untrusted) {
        return new FsMetaValidation(FsMetaVerdict.OK, -1, List.copyOf(untrusted), "");
    }

    /** A failure, with the entry index when the failure is per-entry. */
    public static FsMetaValidation failure(FsMetaVerdict verdict, int firstBadEntry, String detail) {
        return new FsMetaValidation(verdict, firstBadEntry, List.of(), detail);
    }

    /** Whether the pair may be used at all. */
    public boolean usable() {
        return verdict.usable();
    }

    /** Whether a particular entry carries a flag bit this version does not define. */
    public boolean isUntrusted(int index) {
        return untrusted.contains(index);
    }

    /** One line for a log or a terminal. */
    public String describe() {
        if (usable()) {
            return untrusted.isEmpty()
                    ? "ok"
                    : "ok (" + untrusted.size() + " untrusted entry/entries: " + untrusted + ")";
        }
        return verdict.wire()
                + (firstBadEntry >= 0 ? " at entry " + firstBadEntry : "")
                + (detail.isEmpty() ? "" : ": " + detail);
    }
}
