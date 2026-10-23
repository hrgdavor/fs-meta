// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;

/**
 * The sidekick document, {@code files.json} — {@code FORMAT.md} § 7.
 *
 * <p>It is the <em>commit record</em>: it describes the generation a reader is looking at, which is why a
 * writer publishes it last (§ 9) and why it repeats the two data files' sizes. Everything a reader must
 * know before interpreting {@code files.meta}'s bytes is here.</p>
 *
 * <h3>Required and optional keys</h3>
 * <p>A reader requires {@code format}, {@code version}, {@code entrySize}, {@code count},
 * {@code meta.bytes}, {@code txt.bytes} and the four {@code hash} keys; a missing or wrongly-typed one
 * means the document is not understood, which is {@link FsMetaVerdict#UNSUPPORTED_FORMAT}. Every other key
 * — {@code order}, {@code generation}, {@code updated}, {@code writer}, {@code created}, {@code root},
 * {@code scan} — is optional.</p>
 *
 * <h3>Unknown keys survive a rewrite</h3>
 * <p>{@link #extra()} holds the top-level keys this version does not know, and {@link #toJson()} writes
 * them after the known ones. A v1 tool that rewrites a document a v2 writer produced therefore does not
 * destroy the v2 fields it did not understand.</p>
 */
public record FsMetaConfig(
        String format,
        int version,
        int entrySize,
        String order,
        long generation,
        long count,
        long metaBytes,
        long txtBytes,
        String hashContent,
        String hashName,
        long hashSeed,
        String hashNormalize,
        String updated,
        String writer,
        String created,
        String root,
        Map<String, Object> extra) {

    /** The key order {@link #toJson()} writes, which is also the order the vectors' documents use. */
    private static final String[] KNOWN_KEYS = {
            "format", "version", "entrySize", "order", "generation", "count", "meta", "txt",
            "hash", "updated", "writer", "created", "root"
    };

    /** A document for a trio that is about to be written, with the counters a writer owns. */
    public static FsMetaConfig forPublish(
            long count,
            long metaBytes,
            long txtBytes,
            long generation,
            FsMetaHashMode mode,
            String writer,
            String root,
            String created,
            String updated) {
        return new FsMetaConfig(
                FsMetaFormat.FORMAT,
                FsMetaFormat.VERSION,
                FsMetaFormat.ENTRY_SIZE,
                FsMetaFormat.ORDER,
                generation,
                count,
                metaBytes,
                txtBytes,
                FsMetaFormat.HASH_ALGO,
                FsMetaFormat.HASH_ALGO,
                FsMetaFormat.HASH_SEED,
                mode.wire(),
                updated,
                writer,
                created,
                root,
                Map.of());
    }

    /** The current instant in the shape § 7 asks for: RFC 3339 with milliseconds. */
    public static String now() {
        return java.time.format.DateTimeFormatter.ISO_INSTANT.format(Instant.now().truncatedTo(ChronoUnit.MILLIS));
    }

    /**
     * Parses a sidekick document.
     *
     * @throws IllegalArgumentException when the text is not JSON, or a required key is missing or has the
     *                                  wrong type — the caller reports that as
     *                                  {@link FsMetaVerdict#UNSUPPORTED_FORMAT}
     */
    public static FsMetaConfig parse(String json) {
        Object parsed = Json.parse(json);
        if (!(parsed instanceof Map<?, ?> raw)) {
            throw new IllegalArgumentException("files.json must be a JSON object");
        }
        Map<String, Object> document = stringKeyed(raw);
        Map<String, Object> meta = requiredObject(document, "meta");
        Map<String, Object> txt = requiredObject(document, "txt");
        Map<String, Object> hash = requiredObject(document, "hash");

        Map<String, Object> extra = new LinkedHashMap<>();
        for (Map.Entry<String, Object> entry : document.entrySet()) {
            boolean known = false;
            for (String key : KNOWN_KEYS) {
                known |= key.equals(entry.getKey());
            }
            if (!known) {
                extra.put(entry.getKey(), entry.getValue());
            }
        }

        return new FsMetaConfig(
                requiredString(document, "format"),
                Math.toIntExact(requiredLong(document, "version")),
                Math.toIntExact(requiredLong(document, "entrySize")),
                optionalString(document, "order", FsMetaFormat.ORDER),
                optionalLong(document, "generation", 0L),
                requiredLong(document, "count"),
                requiredLong(meta, "bytes"),
                requiredLong(txt, "bytes"),
                requiredString(hash, "content"),
                requiredString(hash, "name"),
                requiredLong(hash, "seed"),
                optionalString(hash, "normalize", FsMetaHashMode.NONE.wire()),
                optionalString(document, "updated", ""),
                optionalString(document, "writer", ""),
                optionalString(document, "created", ""),
                optionalString(document, "root", ""),
                Map.copyOf(extra));
    }

    /** The document as compact JSON, known keys first and the unknown ones preserved after them. */
    public String toJson() {
        Map<String, Object> document = new LinkedHashMap<>();
        document.put("format", format);
        document.put("version", version);
        document.put("entrySize", entrySize);
        document.put("order", order);
        document.put("generation", generation);
        document.put("count", count);
        document.put("meta", Map.of("bytes", metaBytes));
        document.put("txt", Map.of("bytes", txtBytes));
        Map<String, Object> hash = new LinkedHashMap<>();
        hash.put("content", hashContent);
        hash.put("name", hashName);
        hash.put("seed", hashSeed);
        hash.put("normalize", hashNormalize);
        document.put("hash", hash);
        document.put("updated", updated);
        document.put("writer", writer);
        if (!created.isEmpty()) {
            document.put("created", created);
        }
        if (!root.isEmpty()) {
            document.put("root", root);
        }
        document.putAll(extra);
        return Json.write(document);
    }

    /**
     * The writer's hash mode, or {@link FsMetaHashMode#NONE} when the document names one this version does
     * not define. Only a writer is affected — the entries carry their own hashes, and the {@code HASH_LF}
     * flag is authoritative per entry (§ 12).
     */
    public FsMetaHashMode hashMode() {
        return FsMetaHashMode.fromWire(hashNormalize).orElse(FsMetaHashMode.NONE);
    }

    /** The {@code count} this document claims, as an {@code int} for array arithmetic. */
    public int countAsInt() {
        if (count < 0 || count > Integer.MAX_VALUE) {
            throw new IllegalArgumentException("count is not a usable entry count: " + count);
        }
        return (int) count;
    }

    // ------------------------------------------------------------------ helpers

    private static Map<String, Object> stringKeyed(Map<?, ?> raw) {
        Map<String, Object> typed = new LinkedHashMap<>();
        for (Map.Entry<?, ?> entry : raw.entrySet()) {
            typed.put(String.valueOf(entry.getKey()), entry.getValue());
        }
        return typed;
    }

    private static Map<String, Object> requiredObject(Map<String, Object> document, String key) {
        Object value = document.get(key);
        if (!(value instanceof Map<?, ?> map)) {
            throw new IllegalArgumentException("files.json needs an object at '" + key + "'");
        }
        return stringKeyed(map);
    }

    private static String requiredString(Map<String, Object> document, String key) {
        Object value = document.get(key);
        if (!(value instanceof String text)) {
            throw new IllegalArgumentException("files.json needs a string at '" + key + "'");
        }
        return text;
    }

    private static String optionalString(Map<String, Object> document, String key, String fallback) {
        Object value = document.get(key);
        return value instanceof String text ? text : fallback;
    }

    private static long requiredLong(Map<String, Object> document, String key) {
        Object value = document.get(key);
        if (value instanceof Long number) {
            return number;
        }
        if (value instanceof Double number && number == Math.rint(number)) {
            return number.longValue();
        }
        throw new IllegalArgumentException("files.json needs an integer at '" + key + "'");
    }

    private static long optionalLong(Map<String, Object> document, String key, long fallback) {
        Object value = document.get(key);
        if (value instanceof Long number) {
            return number;
        }
        if (value instanceof Double number && number == Math.rint(number)) {
            return number.longValue();
        }
        return fallback;
    }

    /** The optional {@code scan} object, for a caller that wants to report what the writer did. */
    public Optional<Map<String, Object>> scan() {
        Object value = extra.get("scan");
        return value instanceof Map<?, ?> map ? Optional.of(stringKeyed(map)) : Optional.empty();
    }
}
