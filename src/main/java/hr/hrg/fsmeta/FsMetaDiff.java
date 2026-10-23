// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * What changed between two generations — the question a tool asks when it has a trio from last time and one
 * from now.
 *
 * <p>The comparison is the one {@code FORMAT.md} § 11 defines, and the kinds are its cases:
 * {@code contentHash} and {@code sizeBytes} decide a real change ({@link Kind#MODIFIED}), equal content
 * with a moved mtime is a touch ({@link Kind#TOUCHED}), and an entry without a usable fingerprint on either
 * side is {@link Kind#UNKNOWN} rather than a guess. The two implementations' {@code diff} commands print
 * the same lines for the same pair of trios.</p>
 *
 * <p>Names are joined through a map rather than a merge join, even though § 3 orders them: § 8 does not
 * validate the order, so a reader that <em>assumed</em> it would answer wrongly on a corrupt pair instead
 * of answering the same thing as everyone else. The results are sorted into the format's order for output,
 * so the output is stable regardless of how the pair was laid out.</p>
 */
public final class FsMetaDiff {

    /** What happened to one name between two generations. */
    public enum Kind {
        /** The name is in the newer pair only. */
        ADDED("+"),
        /** The name is in the older pair only. */
        REMOVED("-"),
        /** Both have a usable fingerprint and they differ in content hash or size. */
        MODIFIED("M"),
        /** Equal content, different mtime — the file was touched and the derived work is still valid. */
        TOUCHED("T"),
        /** A fingerprint is missing on one side (listing-only or an unknown flag bit): no conclusion. */
        UNKNOWN("?");

        private final String marker;

        Kind(String marker) {
            this.marker = marker;
        }

        /** The one-character marker a {@code diff} line starts with. */
        public String marker() {
            return marker;
        }
    }

    /**
     * One name's change.
     *
     * @param before the older entry, or {@code null} for {@link Kind#ADDED}
     * @param after  the newer entry, or {@code null} for {@link Kind#REMOVED}
     */
    public record Change(Kind kind, String name, FsMetaEntry before, FsMetaEntry after) {

        /** The line {@code fsmeta diff} prints: the marker, a space, the name. */
        public String line() {
            return kind.marker() + " " + name;
        }
    }

    private FsMetaDiff() {
    }

    /** Every name that was added, removed or changed between {@code before} and {@code after}. */
    public static List<Change> between(FsMetaPair before, FsMetaPair after) {
        Map<String, FsMetaEntry> older = index(before);
        Map<String, FsMetaEntry> newer = index(after);
        List<Change> changes = new ArrayList<>();

        for (Map.Entry<String, FsMetaEntry> entry : newer.entrySet()) {
            FsMetaEntry previous = older.get(entry.getKey());
            if (previous == null) {
                changes.add(new Change(Kind.ADDED, entry.getKey(), null, entry.getValue()));
                continue;
            }
            Kind kind = classify(previous, entry.getValue());
            if (kind != null) {
                changes.add(new Change(kind, entry.getKey(), previous, entry.getValue()));
            }
        }
        for (Map.Entry<String, FsMetaEntry> entry : older.entrySet()) {
            if (!newer.containsKey(entry.getKey())) {
                changes.add(new Change(Kind.REMOVED, entry.getKey(), entry.getValue(), null));
            }
        }
        changes.sort(Comparator.comparing(Change::name, FsMetaFormat.NAME_ORDER));
        return changes;
    }

    /** {@code null} when nothing about the file changed — the case a diff does not print. */
    private static Kind classify(FsMetaEntry before, FsMetaEntry after) {
        if (!before.usableFingerprint() || !after.usableFingerprint()) {
            return Kind.UNKNOWN;
        }
        if (before.contentHash() != after.contentHash() || before.sizeBytes() != after.sizeBytes()) {
            return Kind.MODIFIED;
        }
        return before.mtimeMillis() != after.mtimeMillis() ? Kind.TOUCHED : null;
    }

    private static Map<String, FsMetaEntry> index(FsMetaPair pair) {
        Map<String, FsMetaEntry> byName = new LinkedHashMap<>();
        for (int index = 0; index < pair.size(); index++) {
            byName.put(pair.name(index), pair.entry(index));
        }
        return byName;
    }
}
