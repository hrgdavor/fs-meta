// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;
import java.util.OptionalInt;

/**
 * A validated trio, in memory: the entries, their names, and the lookups a consumer asks of them.
 *
 * <p>Construct one with {@link #load(Path)} (which reads and validates the three files) or
 * {@link #of(byte[], byte[], FsMetaConfig)} when the bytes come from somewhere else. Both insist on an
 * {@code ok} verdict: an unusable trio is a {@link FsMetaLoad} with a failure, never a pair that a caller
 * might read a stale field from.</p>
 *
 * <h3>Lookup is by hash, then verified</h3>
 * <p>{@link #find(String)} hashes the name, binary-searches the entries' {@code nameHash} values (sorted
 * once at construction), and then compares the stored name — so a 64-bit collision costs a comparison
 * rather than a wrong answer. The lookup deliberately does not binary-search {@code files.txt}: § 3 says a
 * writer orders the names, but § 8 does not validate the order, because order is the writer's obligation
 * and a corrupt pair should not be able to make a reader answer wrongly. For the same reason
 * {@link FsMetaDiff} builds a map rather than assuming a merge join is possible.</p>
 */
public final class FsMetaPair {

    private final byte[] meta;
    private final byte[] txt;
    private final FsMetaConfig config;
    private final List<FsMetaEntry> entries;
    private final String[] names;
    private final boolean[] untrusted;
    private final FsMetaValidation validation;

    /** The entries' name hashes, unsigned-ascending, and the entry index each belongs to. */
    private final long[] sortedHashes;
    private final int[] sortedIndices;

    private FsMetaPair(byte[] meta, byte[] txt, FsMetaConfig config, FsMetaValidation validation) {
        this.meta = meta;
        this.txt = txt;
        this.config = config;
        this.validation = validation;
        this.entries = FsMetaCodec.decodeEntries(meta);
        this.names = new String[entries.size()];
        this.untrusted = new boolean[entries.size()];
        this.sortedHashes = new long[entries.size()];
        this.sortedIndices = new int[entries.size()];
        for (int index = 0; index < entries.size(); index++) {
            FsMetaEntry entry = entries.get(index);
            names[index] = FsMetaValidator.nameAt(txt, entry);
            untrusted[index] = !entry.trusted();
            sortedHashes[index] = entry.nameHash();
            sortedIndices[index] = index;
        }
        // Sort hash/index pairs together, unsigned, so a lookup is a binary search. Bottom-up merge sort
        // over two parallel arrays: O(n log n), no boxing, and no comparator call per element — which
        // matters, because a monorepo's trio can hold hundreds of thousands of entries.
        sortHashes(this.sortedHashes, this.sortedIndices);
    }

    /** Sorts {@code hashes} unsigned-ascending, carrying each entry's index along. */
    private static void sortHashes(long[] hashes, int[] indices) {
        int length = hashes.length;
        if (length < 2) {
            return;
        }
        long[] hashesBuffer = new long[length];
        int[] indicesBuffer = new int[length];
        for (int width = 1; width < length; width *= 2) {
            for (int start = 0; start < length; start += 2 * width) {
                int middle = Math.min(start + width, length);
                int end = Math.min(start + 2 * width, length);
                mergeRuns(hashes, indices, hashesBuffer, indicesBuffer, start, middle, end);
            }
        }
    }

    /** Merges the two ascending runs {@code [start, middle)} and {@code [middle, end)} of the pair arrays. */
    private static void mergeRuns(
            long[] hashes, int[] indices, long[] hashesBuffer, int[] indicesBuffer, int start, int middle, int end) {
        int left = start;
        int right = middle;
        int at = start;
        while (left < middle && right < end) {
            boolean takeLeft = Long.compareUnsigned(hashes[left], hashes[right]) <= 0;
            hashesBuffer[at] = takeLeft ? hashes[left] : hashes[right];
            indicesBuffer[at] = takeLeft ? indices[left] : indices[right];
            if (takeLeft) {
                left++;
            } else {
                right++;
            }
            at++;
        }
        while (left < middle) {
            hashesBuffer[at] = hashes[left];
            indicesBuffer[at] = indices[left];
            left++;
            at++;
        }
        while (right < end) {
            hashesBuffer[at] = hashes[right];
            indicesBuffer[at] = indices[right];
            right++;
            at++;
        }
        System.arraycopy(hashesBuffer, start, hashes, start, end - start);
        System.arraycopy(indicesBuffer, start, indices, start, end - start);
    }

    /**
     * Wraps already-validated bytes.
     *
     * @throws IllegalArgumentException when the verdict is not {@code ok} — a caller holding a failure has
     *                                  nothing to read a field from
     */
    public static FsMetaPair of(byte[] meta, byte[] txt, FsMetaConfig config) {
        FsMetaValidation validation = FsMetaValidator.validate(meta, txt, config);
        if (!validation.usable()) {
            throw new IllegalArgumentException("the trio is not usable: " + validation.describe());
        }
        return new FsMetaPair(meta, txt, config, validation);
    }

    /** Reads {@code files.meta}, {@code files.txt} and {@code files.json} from {@code directory}. */
    public static FsMetaLoad load(Path directory) throws IOException {
        Path metaFile = directory.resolve(FsMetaFormat.META_FILE);
        Path txtFile = directory.resolve(FsMetaFormat.TXT_FILE);
        Path jsonFile = directory.resolve(FsMetaFormat.JSON_FILE);
        byte[] meta = Files.readAllBytes(metaFile);
        byte[] txt = Files.readAllBytes(txtFile);

        FsMetaConfig config;
        try {
            config = FsMetaConfig.parse(new String(Files.readAllBytes(jsonFile), StandardCharsets.UTF_8));
        } catch (RuntimeException malformed) {
            // § 8 check 1: a document that cannot be read at all is the same verdict as one that is not ours.
            return new FsMetaLoad(directory, FsMetaVerdict.UNSUPPORTED_FORMAT, null, null, malformed.getMessage());
        }

        FsMetaValidation validation = FsMetaValidator.validate(meta, txt, config);
        if (!validation.usable()) {
            return new FsMetaLoad(directory, validation.verdict(), config, null, validation.detail());
        }
        return new FsMetaLoad(directory, FsMetaVerdict.OK, config, new FsMetaPair(meta, txt, config, validation), "");
    }

    /**
     * Reads the trio when all three files exist, and returns {@code null} when one of them does not — the
     * normal state of a checkout that has never been scanned.
     */
    public static FsMetaLoad loadIfPresent(Path directory) throws IOException {
        if (!Files.isRegularFile(directory.resolve(FsMetaFormat.META_FILE))
                || !Files.isRegularFile(directory.resolve(FsMetaFormat.TXT_FILE))
                || !Files.isRegularFile(directory.resolve(FsMetaFormat.JSON_FILE))) {
            return null;
        }
        return load(directory);
    }

    /** Reads the trio and reports a missing file as such rather than as an empty load. */
    public static FsMetaLoad loadOrFail(Path directory) throws IOException {
        FsMetaLoad load = loadIfPresent(directory);
        if (load == null) {
            throw new NoSuchFileException(directory.resolve(FsMetaFormat.JSON_FILE).toString(),
                    null, "the fs-meta trio is not complete in " + directory);
        }
        return load;
    }

    /** How many entries the pair holds — the same as the number of names in {@code files.txt}. */
    public int size() {
        return entries.size();
    }

    /** The entry at {@code index}. */
    public FsMetaEntry entry(int index) {
        return entries.get(index);
    }

    /** The name at {@code index}, decoded from {@code files.txt}. */
    public String name(int index) {
        return names[index];
    }

    /** Every entry, in the order they appear in the pair. */
    public List<FsMetaEntry> entries() {
        return entries;
    }

    /** Every name, in the order it appears in the pair. */
    public List<String> names() {
        return List.of(names);
    }

    /** The document that describes this generation. */
    public FsMetaConfig config() {
        return config;
    }

    /** What validation decided — {@code ok}, possibly with untrusted entries. */
    public FsMetaValidation validation() {
        return validation;
    }

    /** The raw {@code files.meta} bytes, for a caller that wants to hand them on unchanged. */
    public byte[] metaBytes() {
        return meta.clone();
    }

    /** The raw {@code files.txt} bytes. */
    public byte[] txtBytes() {
        return txt.clone();
    }

    /** Whether the entry at {@code index} carries a flag bit this version does not define (§ 6). */
    public boolean untrusted(int index) {
        return untrusted[index];
    }

    /**
     * The index of the entry named {@code name}, or empty when the pair does not list it.
     *
     * <p>A name the pair does not list is the answer "not in this snapshot": new, deleted, or excluded by
     * the writer (§ 11, step 2). It is not an error.</p>
     */
    public OptionalInt find(String name) {
        long wanted = FsMetaHash.ofName(name);
        int low = lowerBound(wanted);
        for (int i = low; i < sortedIndices.length && sortedHashes[i] == wanted; i++) {
            int index = sortedIndices[i];
            // § 3: a directory's stored line may carry the trailing slash that bounds its subtree, but the
            // path a lookup is given is the one without it. A file's stored form has no trailing slash.
            String stored = names[index];
            String logical = entries.get(index).directory() && stored.endsWith("/")
                    ? stored.substring(0, stored.length() - 1)
                    : stored;
            if (logical.equals(name)) {
                return OptionalInt.of(index);
            }
        }
        return OptionalInt.empty();
    }

    /** Whether the pair lists {@code name}. */
    public boolean contains(String name) {
        return find(name).isPresent();
    }

    /**
     * The entry for {@code name}, or {@code null}.
     *
     * <p>Note what a present entry does <em>not</em> mean: § 11 is the contract for what may be concluded
     * from it. Check {@link FsMetaEntry#usableFingerprint()} before comparing a hash, and read the file
     * when the fingerprint's {@code mtimeNs}/{@code sizeBytes} disagree with what the caller's own
     * record of the file says.</p>
     */
    public FsMetaEntry entryOrNull(String name) {
        OptionalInt index = find(name);
        return index.isPresent() ? entries.get(index.getAsInt()) : null;
    }

    /** A one-line summary: the generation, the entry count and the verdict. */
    public String describe() {
        return "fs-meta generation " + config.generation() + ", " + size() + " entries, "
                + validation.describe();
    }

    private int lowerBound(long hash) {
        int low = 0;
        int high = sortedHashes.length;
        while (low < high) {
            int middle = (low + high) >>> 1;
            if (Long.compareUnsigned(sortedHashes[middle], hash) < 0) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low;
    }

    @Override
    public String toString() {
        return "FsMetaPair[" + config.generation() + ", " + size() + " entries, first="
                + (names.length == 0 ? "-" : names[0]) + ", last="
                + (names.length == 0 ? "-" : names[names.length - 1]) + "]";
    }

    /** The names, sorted the way § 3 defines — what a writer publishes and a repair produces. */
    public List<String> namesInFormatOrder() {
        String[] sorted = names.clone();
        Arrays.sort(sorted, FsMetaFormat.NAME_ORDER);
        return List.of(sorted);
    }
}
