// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.nio.charset.StandardCharsets;
import java.util.List;

/**
 * {@code FORMAT.md} § 8: the checks a reader owes before it trusts a trio.
 *
 * <p>The order is part of the contract, because the first failure is the verdict a reader reports and two
 * implementations must report the same one for the same bytes. The shared vectors assert exactly that,
 * including cases whose whole point is the order (a document that is not ours <em>and</em> has a bad size
 * is {@code unsupported-format}, an entry that is both out of range and mis-hashed is
 * {@code entry-out-of-range}, and a size that agrees while the bytes do not is {@code meta-hash-mismatch}).</p>
 *
 * <p>A failure never means "the caller's work fails": it means the trio is unusable and the caller falls
 * back to the file system (§ 1). Validation does not write anything and does not throw for bad input.</p>
 */
public final class FsMetaValidator {

    private FsMetaValidator() {
    }

    /**
     * Validates the two data files against the document.
     *
     * @param meta   the bytes of {@code files.meta}
     * @param txt    the bytes of {@code files.txt}
     * @param config the parsed sidekick document
     */
    public static FsMetaValidation validate(byte[] meta, byte[] txt, FsMetaConfig config) {
        // 2. the format's name. (Check 1 — the document parses and has the required keys — has already
        //    happened in FsMetaConfig.parse; a caller that could not parse it reports unsupported-format
        //    without reaching this method.)
        if (!FsMetaFormat.FORMAT.equals(config.format())) {
            return FsMetaValidation.failure(FsMetaVerdict.UNSUPPORTED_FORMAT, -1,
                    "the document's format is '" + config.format() + "', not '" + FsMetaFormat.FORMAT + "'");
        }
        // 3. the version.
        if (config.version() != FsMetaFormat.VERSION) {
            return FsMetaValidation.failure(FsMetaVerdict.UNSUPPORTED_VERSION, -1,
                    "version " + config.version() + " is not implemented (this reader reads and writes "
                            + FsMetaFormat.VERSION + ")");
        }
        // 4. the entry size, which is part of the gate rather than a field to scale.
        if (config.entrySize() != FsMetaFormat.ENTRY_SIZE) {
            return FsMetaValidation.failure(FsMetaVerdict.UNSUPPORTED_ENTRY_SIZE, -1,
                    "entrySize " + config.entrySize() + " is not this version's " + FsMetaFormat.ENTRY_SIZE);
        }
        // 5. the hash identity: the values in the entries are only comparable if the algorithm is the one
        //    this version defines. (The normalisation is not checked here: it decides which bytes a writer
        //    hashed, not what the 64-bit value means, and the entry's HASH_LF flag carries it per entry.)
        if (!FsMetaFormat.HASH_ALGO.equals(config.hashContent())
                || !FsMetaFormat.HASH_ALGO.equals(config.hashName())
                || config.hashSeed() != FsMetaFormat.HASH_SEED) {
            return FsMetaValidation.failure(FsMetaVerdict.UNSUPPORTED_HASH, -1,
                    "the document's hash is " + config.hashContent() + "/" + config.hashName()
                            + " with seed " + config.hashSeed() + ", not " + FsMetaFormat.HASH_ALGO
                            + " with seed " + FsMetaFormat.HASH_SEED);
        }

        // 6. the meta file's size: a multiple of the entry size, the document's count, and the document's
        //    recorded size — three ways of saying the same thing, which is what catches a torn publish.
        long metaBytes = meta.length;
        if ((metaBytes & (FsMetaFormat.ENTRY_SIZE - 1)) != 0) {
            return FsMetaValidation.failure(FsMetaVerdict.META_SIZE_MISMATCH, -1,
                    "files.meta is " + metaBytes + " bytes, not a whole number of "
                            + FsMetaFormat.ENTRY_SIZE + "-byte entries");
        }
        if (config.count() < 0 || (metaBytes >>> 6) != config.count()) {
            return FsMetaValidation.failure(FsMetaVerdict.META_SIZE_MISMATCH, -1,
                    "files.meta holds " + (metaBytes >>> 6) + " entries but the document says "
                            + config.count());
        }
        if (metaBytes != config.metaBytes()) {
            return FsMetaValidation.failure(FsMetaVerdict.META_SIZE_MISMATCH, -1,
                    "files.meta is " + metaBytes + " bytes but the document records " + config.metaBytes());
        }

        // 6b. the size is not a claim about the bytes; the whole-file hash is. Checked before any entry, or a
        //     corrupted meta would be reported as the first thing *inside* it that looks wrong.
        String actualMetaHash = FsMetaHash.hex(FsMetaHash.of(meta));
        if (!actualMetaHash.equals(config.metaWyhash())) {
            return FsMetaValidation.failure(FsMetaVerdict.META_HASH_MISMATCH, -1,
                    "wyhash(files.meta) is " + actualMetaHash + ", meta.wyhash says " + config.metaWyhash());
        }

        // 7. the text file: the recorded size, one LF per name, and a terminator at the end. An empty
        //    snapshot (no files at all) is a legitimate state: count 0 means an empty file and no lines.
        long txtBytes = txt.length;
        if (txtBytes != config.txtBytes()) {
            return FsMetaValidation.failure(FsMetaVerdict.TXT_SIZE_MISMATCH, -1,
                    "files.txt is " + txtBytes + " bytes but the document records " + config.txtBytes());
        }
        if (config.count() == 0) {
            if (txtBytes != 0) {
                return FsMetaValidation.failure(FsMetaVerdict.TXT_SIZE_MISMATCH, -1,
                        "the document says there are no entries, but files.txt holds " + txtBytes + " bytes");
            }
        } else {
            if (txtBytes == 0 || txt[(int) txtBytes - 1] != FsMetaFormat.LF) {
                return FsMetaValidation.failure(FsMetaVerdict.TXT_SIZE_MISMATCH, -1,
                        "files.txt does not end with LF, so its last name is unterminated");
            }
            long lines = 0;
            for (byte value : txt) {
                if (value == FsMetaFormat.LF) {
                    lines++;
                }
            }
            if (lines != config.count()) {
                return FsMetaValidation.failure(FsMetaVerdict.TXT_SIZE_MISMATCH, -1,
                        "files.txt holds " + lines + " names but the document says " + config.count());
            }
        }

        // 7b. the text file's own hash, before a single name is read out of it.
        String actualTxtHash = FsMetaHash.hex(FsMetaHash.of(txt));
        if (!actualTxtHash.equals(config.txtWyhash())) {
            return FsMetaValidation.failure(FsMetaVerdict.TXT_HASH_MISMATCH, -1,
                    "wyhash(files.txt) is " + actualTxtHash + ", txt.wyhash says " + config.txtWyhash());
        }

        // 8. each entry: its name slice is inside files.txt, is terminated by LF, holds no LF, and names
        //    something (an empty name is not a path, § 3).
        List<FsMetaEntry> entries = FsMetaCodec.decodeEntries(meta);
        for (int index = 0; index < entries.size(); index++) {
            FsMetaEntry entry = entries.get(index);
            long offset = entry.nameOffset();
            int length = entry.nameLength();
            if (length <= 0) {
                return FsMetaValidation.failure(FsMetaVerdict.ENTRY_OUT_OF_RANGE, index,
                        "the entry's nameLength is " + length + ", which names nothing");
            }
            if (offset < 0 || offset >= txtBytes || offset + length >= txtBytes) {
                return FsMetaValidation.failure(FsMetaVerdict.ENTRY_OUT_OF_RANGE, index,
                        "the entry's name slice (" + offset + " + " + length + ") is not inside files.txt ("
                                + txtBytes + " bytes)");
            }
            if (txt[(int) (offset + length)] != FsMetaFormat.LF) {
                return FsMetaValidation.failure(FsMetaVerdict.ENTRY_OUT_OF_RANGE, index,
                        "the byte after the entry's name is not LF");
            }
            for (int i = 0; i < length; i++) {
                if (txt[(int) offset + i] == FsMetaFormat.LF) {
                    return FsMetaValidation.failure(FsMetaVerdict.ENTRY_OUT_OF_RANGE, index,
                            "the entry's name slice contains an LF");
                }
            }
        }

        // 9. each entry's name hashes to the nameHash it recorded — what makes the pair self-identifying.
        //    A directory's stored line carries the trailing slash that bounds its subtree (§ 3, § 4), but the
        //    hash and the lookup name are the path without it. Stripping here accepts both the spec's stored
        //    form and a stored form that omits the slash, because the hash is over the same path either way.
        for (int index = 0; index < entries.size(); index++) {
            FsMetaEntry entry = entries.get(index);
            int offset = (int) entry.nameOffset();
            int length = entry.nameLength();
            int hashedLength = length;
            if (entry.directory() && length > 1 && txt[offset + length - 1] == '/') {
                hashedLength = length - 1;
            }
            byte[] name = new byte[hashedLength];
            System.arraycopy(txt, offset, name, 0, hashedLength);
            long actual = FsMetaHash.of(name);
            if (actual != entry.nameHash()) {
                return FsMetaValidation.failure(FsMetaVerdict.NAME_HASH_MISMATCH, index,
                        "the name at the entry's offset hashes to " + FsMetaHash.hex(actual)
                                + ", not " + FsMetaHash.hex(entry.nameHash()));
            }
        }

        // 10. the flags word: exactly one kind bit, nothing outside § 6's vocabulary, and HASH_LF only
        //     where CONTENT_KNOWN says a hash was taken. There is no "untrusted but usable" entry in v1.
        for (int index = 0; index < entries.size(); index++) {
            FsMetaEntry entry = entries.get(index);
            if (!FsMetaFormat.isValidFlags(entry.flags())) {
                return FsMetaValidation.failure(FsMetaVerdict.INVALID_FLAGS, index,
                        "the entry's flags are 0x" + Integer.toHexString(entry.flags())
                                + ": not exactly one of file/dir/symlink, or a bit this version does not define");
            }
        }

        return FsMetaValidation.ok();
    }

    /** The {@code String} form of a name slice, for a caller that already knows the slice is valid. */
    static String nameAt(byte[] txt, FsMetaEntry entry) {
        return new String(txt, (int) entry.nameOffset(), entry.nameLength(), StandardCharsets.UTF_8);
    }
}
