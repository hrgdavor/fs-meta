// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

import hr.hrg.wyhash.Wyhash64;

/**
 * The hash half of the format: {@code wyhash64}, seed 0, and the LF normalisation (§ 12).
 *
 * <p>The algorithm is not chosen here. {@code hr.hrg.wyhash:wyhash:1.0.0} is what {@code java-watch-core}'s
 * {@code ChecksumDatabase}, {@code jcodebuddy-agent}'s {@code MetadataCache} and the engine's
 * {@code ContentHash} hash with, and DEC-028/DEC-029 reserved <em>one</em> content identity for this
 * repository — so this class calls the library rather than carrying another transcription of it. Zig's
 * {@code std.hash.Wyhash} produces the same values, which is what lets a Zig implementation land later
 * against the same vectors.</p>
 *
 * <p>{@link #ofText} and {@link #normalizeLf} reproduce the watch agent's normaliser byte for byte:
 * {@code \r\n} becomes {@code \n}, and a lone {@code \r} becomes {@code \n}.</p>
 */
public final class FsMetaHash {

    private FsMetaHash() {
    }

    /** The 64-bit hash of {@code content}, as stored in an entry. */
    public static long of(byte[] content) {
        return Wyhash64.hash(FsMetaFormat.HASH_SEED, content);
    }

    /** The hash of a name's UTF-8 bytes, without any terminator — the entry's {@code nameHash}. */
    public static long ofName(String name) {
        return of(name.getBytes(StandardCharsets.UTF_8));
    }

    /** The 16 lowercase hex characters a document or a message carries. */
    public static String hex(long hash) {
        return String.format("%016x", hash);
    }

    /**
     * What a hash of one file's content produced: the value, and whether it was taken over normalised
     * bytes — which is what the entry's {@code HASH_LF} flag records.
     */
    public record Hashed(long hash, boolean hashLf) {
    }

    /** Hashes {@code content} under {@code mode}, deciding per file for {@link FsMetaHashMode#TEXT}. */
    public static Hashed hash(byte[] content, FsMetaHashMode mode) {
        boolean normalise = switch (mode) {
            case NONE -> false;
            case LF -> true;
            case TEXT -> looksLikeText(content);
        };
        return normalise ? new Hashed(of(normalizeLf(content)), true) : new Hashed(of(content), false);
    }

    /**
     * {@code \r\n} and a lone {@code \r} become {@code \n}; every other byte is untouched.
     *
     * <p>The same transformation {@code ChecksumDatabase.normalizeLineEndings} performs — on the bytes
     * before hashing, never on the file on disk.</p>
     */
    public static byte[] normalizeLf(byte[] content) {
        ByteArrayOutputStream out = new ByteArrayOutputStream(content.length);
        int i = 0;
        while (i < content.length) {
            byte current = content[i];
            if (current == '\r') {
                out.write('\n');
                i += (i + 1 < content.length && content[i + 1] == '\n') ? 2 : 1;
            } else {
                out.write(current);
                i += 1;
            }
        }
        return out.toByteArray();
    }

    /**
     * Whether content looks like text: no NUL byte, which is the same test {@code git} applies before it
     * treats a file as text. An empty file is text (it normalises to itself either way).
     */
    public static boolean looksLikeText(byte[] content) {
        for (byte value : content) {
            if (value == 0) {
                return false;
            }
        }
        return true;
    }

    /** The UTF-8 bytes of {@code text} — what a caller hashes for a text file's content. */
    public static byte[] utf8(String text) {
        return text.getBytes(StandardCharsets.UTF_8);
    }
}
