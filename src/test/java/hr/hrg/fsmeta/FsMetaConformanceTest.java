// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

/**
 * The Java implementation against the shared vectors — {@code conformance/fsmeta-vectors.json}, which the
 * Bun implementation asserts too (and a Zig one will).
 *
 * <p>This is the test that makes the format a contract rather than a description: every blob comes from the
 * published specification's worked example, not from this implementation's encoder, and the invalid cases
 * pin the verdict two implementations must agree on. The hash cases are library-produced values (see
 * {@code hr.hrg.wyhash:wyhash:1.0.0} and {@code ContentHashTest}), so a divergence in the hash is caught
 * here rather than in a consumer's table.</p>
 */
class FsMetaConformanceTest {

    private static final Path VECTORS = locateVectors();

    private static Path locateVectors() {
        List<Path> candidates = List.of(
                Path.of("conformance", "fsmeta-vectors.json"),
                Path.of("fs-meta", "conformance", "fsmeta-vectors.json"));
        for (Path candidate : candidates) {
            if (Files.isRegularFile(candidate)) {
                return candidate;
            }
        }
        throw new IllegalStateException("fsmeta-vectors.json not found from "
                + Path.of("").toAbsolutePath() + "; looked at " + candidates);
    }

    private static Map<String, Object> vectors() throws IOException {
        return asMap(Json.parse(Files.readString(VECTORS, StandardCharsets.UTF_8)));
    }

    @Test
    void theHashMatchesEveryVectorCase() throws IOException {
        Map<String, Object> vectors = vectors();
        int checked = 0;
        for (Object entry : asList(vectors.get("hashCases"))) {
            Map<String, Object> vector = asMap(entry);
            String label = text(vector.get("label"));
            byte[] bytes = vector.containsKey("text")
                    ? text(vector.get("text")).getBytes(StandardCharsets.UTF_8)
                    : HexFormat.of().parseHex(text(vector.get("hex")));
            Assertions.assertEquals(text(vector.get("wyhash64")), FsMetaHash.hex(FsMetaHash.of(bytes)),
                    "wyhash64 of vector '" + label + "'");
            checked++;
        }
        Assertions.assertTrue(checked >= 20, "the vector file should exercise the hash's branches; got " + checked);
    }

    @Test
    void everyPairCaseReachesTheVerdictItRecords() throws IOException {
        Map<String, Object> vectors = vectors();
        int checked = 0;
        for (Object entry : asList(vectors.get("cases"))) {
            Map<String, Object> vector = asMap(entry);
            String label = text(vector.get("label"));
            FsMetaVerdict expected = FsMetaVerdict.fromWire(text(vector.get("verdict")))
                    .orElseThrow(() -> new AssertionError("the vectors name an unknown verdict in '" + label + "'"));
            FsMetaConfig config = FsMetaConfig.parse(Json.write(vector.get("json")));
            byte[] meta = HexFormat.of().parseHex(text(vector.get("metaHex")));
            byte[] txt = HexFormat.of().parseHex(text(vector.get("txtHex")));

            FsMetaValidation validation = FsMetaValidator.validate(meta, txt, config);
            Assertions.assertEquals(expected, validation.verdict(), "verdict for case '" + label + "'");
            boolean perEntry = expected == FsMetaVerdict.ENTRY_OUT_OF_RANGE
                    || expected == FsMetaVerdict.NAME_HASH_MISMATCH;
            if (perEntry) {
                Assertions.assertTrue(validation.firstBadEntry() >= 0,
                        "case '" + label + "' fails on one entry, so it must name the index");
            } else {
                Assertions.assertEquals(-1, validation.firstBadEntry(),
                        "case '" + label + "' fails before any entry is examined");
            }
            Assertions.assertEquals(untrustedOf(vector), validation.untrusted(),
                    "untrusted entries for case '" + label + "'");
            checked++;
        }
        Assertions.assertTrue(checked >= 10, "the vector file should cover the gate and the checks; got " + checked);
    }

    @Test
    void theValidCaseIsByteExactInBothDirections() throws IOException {
        Map<String, Object> valid = caseNamed("valid");
        FsMetaConfig config = FsMetaConfig.parse(Json.write(valid.get("json")));
        byte[] meta = HexFormat.of().parseHex(text(valid.get("metaHex")));
        byte[] txt = HexFormat.of().parseHex(text(valid.get("txtHex")));

        FsMetaPair pair = FsMetaPair.of(meta, txt, config);
        Assertions.assertEquals(List.of("a.txt", "src/b.java"), pair.names());

        // Decoding the published bytes and re-encoding them must give exactly the published bytes back:
        // that is the encoder agreeing with the specification rather than with itself.
        Assertions.assertArrayEquals(meta, FsMetaCodec.encodeEntries(pair.entries()),
                "re-encoding the decoded entries must reproduce files.meta");
        Assertions.assertArrayEquals(txt, FsMetaCodec.encodeNames(pair.names()),
                "re-encoding the decoded names must reproduce files.txt");

        Assertions.assertEquals("e6d129338e065990", FsMetaHash.hex(pair.entry(0).contentHash()));
        Assertions.assertEquals(6L, pair.entry(0).sizeBytes());
        Assertions.assertEquals(0L, pair.entry(0).nameOffset());
        Assertions.assertEquals(5, pair.entry(0).nameLength());
        Assertions.assertEquals(6L, pair.entry(1).nameOffset());
        Assertions.assertEquals(10, pair.entry(1).nameLength());
    }

    @Test
    void everyVerdictInTheFileIsOneThisVersionDefines() throws IOException {
        for (Object entry : asList(vectors().get("cases"))) {
            String wire = text(asMap(entry).get("verdict"));
            Assertions.assertTrue(FsMetaVerdict.fromWire(wire).isPresent(),
                    "the vectors use the verdict '" + wire + "', which this version must define");
        }
    }

    @Test
    void theRepairCaseRecoversThePairingFromTheHashes() throws IOException {
        Map<String, Object> repair = asMap(vectors().get("repairCase"));
        byte[] meta = HexFormat.of().parseHex(text(repair.get("metaHex")));
        byte[] txt = HexFormat.of().parseHex(text(repair.get("txtHex")));
        FsMetaConfig config = FsMetaConfig.parse(Json.write(repair.get("json")));

        FsMetaValidation validation = FsMetaValidator.validate(meta, txt, config);
        Assertions.assertEquals(FsMetaVerdict.fromWire(text(repair.get("verdict"))).orElseThrow(),
                validation.verdict(), "the repair case's offsets point at the wrong lines");

        List<FsMetaRepair.Pairing> recovered = FsMetaRepair.pairByHash(meta, txt)
                .orElseThrow(() -> new AssertionError("the pairing must be recoverable from the hashes"));
        List<String> expected = new ArrayList<>();
        for (Object entry : asList(repair.get("recovered"))) {
            Map<String, Object> one = asMap(entry);
            int index = Math.toIntExact((Long) one.get("entry"));
            Assertions.assertEquals(index, recovered.get(index).entryIndex());
            expected.add(text(one.get("name")));
        }
        for (int i = 0; i < recovered.size(); i++) {
            Assertions.assertEquals(expected.get(i), recovered.get(i).name(),
                    "entry " + i + " must be paired with the name whose hash it recorded");
        }
        List<String> sorted = new ArrayList<>(expected);
        sorted.sort(FsMetaFormat.NAME_ORDER);
        Assertions.assertEquals(asTextList(repair.get("sortedNames")), sorted,
                "the repaired pairing is republished in name order");
    }

    // ------------------------------------------------------------------ vector navigation

    private static Map<String, Object> caseNamed(String label) throws IOException {
        for (Object entry : asList(vectors().get("cases"))) {
            Map<String, Object> vector = asMap(entry);
            if (label.equals(text(vector.get("label")))) {
                return vector;
            }
        }
        throw new AssertionError("no vector case named '" + label + "'");
    }

    private static List<Integer> untrustedOf(Map<String, Object> vector) {
        List<Integer> indices = new ArrayList<>();
        for (Object index : asList(vector.get("untrusted"))) {
            indices.add(Math.toIntExact((Long) index));
        }
        return indices;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> asMap(Object value) {
        return (Map<String, Object>) value;
    }

    @SuppressWarnings("unchecked")
    private static List<Object> asList(Object value) {
        return (List<Object>) value;
    }

    private static List<String> asTextList(Object value) {
        List<String> texts = new ArrayList<>();
        for (Object element : asList(value)) {
            texts.add(text(element));
        }
        return texts;
    }

    private static String text(Object value) {
        return (String) value;
    }
}