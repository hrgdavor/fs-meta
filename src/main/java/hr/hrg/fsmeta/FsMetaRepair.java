// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/**
 * {@code FORMAT.md} § 10: pairing entries to names by hash, for a pair whose offsets are broken.
 *
 * <p>This is the recovery {@code nameHash} exists for. When the entries' offsets point at the wrong lines
 * — a truncated write, a hand-edited {@code files.txt}, a bad merge — the pair fails validation with
 * {@code name-hash-mismatch}, and the pairing can still be rebuilt because every entry says which name it
 * belongs to. The rule is deliberately strict: every entry must find a distinct line, and every line must
 * be claimed, or the answer is "unusable" rather than a guess.</p>
 *
 * <p>Reading does not repair — a reader validates and falls back (§ 8). This is the writer's side, and
 * {@code fsmeta repair} is the command that uses it: repair the pairing, re-sort by name and republish.</p>
 */
public final class FsMetaRepair {

    /** One entry's recovered name. */
    public record Pairing(int entryIndex, String name) {
    }

    private FsMetaRepair() {
    }

    /**
     * Rebuilds the entry-to-name pairing from the hashes.
     *
     * @return the pairing in entry order, or empty when it cannot be recovered (an entry with no matching
     *         line, a line claimed twice, or a line nobody claims)
     */
    public static Optional<List<Pairing>> pairByHash(byte[] meta, byte[] txt) {
        if (meta.length % FsMetaFormat.ENTRY_SIZE != 0) {
            return Optional.empty();
        }
        List<FsMetaEntry> entries = FsMetaCodec.decodeEntries(meta);
        List<String> names = names(txt);
        if (names.size() != entries.size()) {
            return Optional.empty();
        }

        // The names' hashes, once each: a rebuild matches on the same value the entry recorded.
        long[] nameHashes = new long[names.size()];
        for (int i = 0; i < names.size(); i++) {
            nameHashes[i] = FsMetaHash.ofName(names.get(i));
        }

        boolean[] lineUsed = new boolean[names.size()];
        List<Pairing> pairing = new ArrayList<>(entries.size());
        for (int entryIndex = 0; entryIndex < entries.size(); entryIndex++) {
            FsMetaEntry entry = entries.get(entryIndex);
            int found = -1;
            for (int line = 0; line < names.size(); line++) {
                if (lineUsed[line] || nameHashes[line] != entry.nameHash()) {
                    continue;
                }
                if (found >= 0) {
                    // Two lines hash alike. The entry also recorded how many bytes its name is, which
                    // separates them — and if it does not, the pairing would be a guess, so it is refused.
                    boolean firstFits = FsMetaCodec.utf8Length(names.get(found)) == entry.nameLength();
                    boolean thisFits = FsMetaCodec.utf8Length(names.get(line)) == entry.nameLength();
                    if (firstFits == thisFits) {
                        return Optional.empty();
                    }
                    if (thisFits) {
                        found = line;
                    }
                    continue;
                }
                found = line;
            }
            if (found < 0) {
                return Optional.empty();
            }
            lineUsed[found] = true;
            pairing.add(new Pairing(entryIndex, names.get(found)));
        }
        return Optional.of(List.copyOf(pairing));
    }

    /**
     * The names in {@code files.txt}, in file order: LF-separated, with a final unterminated line accepted
     * so that a truncated write is still readable enough to repair.
     */
    public static List<String> names(byte[] txt) {
        List<String> names = new ArrayList<>();
        int start = 0;
        for (int i = 0; i < txt.length; i++) {
            if (txt[i] == FsMetaFormat.LF) {
                names.add(new String(txt, start, i - start, StandardCharsets.UTF_8));
                start = i + 1;
            }
        }
        if (start < txt.length) {
            names.add(new String(txt, start, txt.length - start, StandardCharsets.UTF_8));
        }
        return names;
    }
}
