// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * Reading a pair: lookup, the untrusted entry, the empty snapshot, and the two ways a trio can be absent or
 * unusable.
 */
class FsMetaPairTest {

    /** A pair built here, so the test does not depend on the writer's own output shape. */
    private static FsMetaPair pairOf(List<String> names, List<FsMetaEntry> entries) {
        byte[] txt = FsMetaCodec.encodeNames(names);
        byte[] meta = FsMetaCodec.encodeEntries(entries);
        FsMetaConfig config = FsMetaConfig.forPublish(entries.size(), meta.length, txt.length, 3L,
                FsMetaHashMode.NONE, "test/1", "/tmp/root", "2026-01-01T00:00:00.000Z",
                "2026-01-01T00:00:01.000Z");
        return FsMetaPair.of(meta, txt, config);
    }

    @Test
    void findsANameByHashAndVerifiesIt() {
        FsMetaEntry first = FsMetaEntry.forFile("a.txt", 10L, 6L, 0x1234L, 0L, false);
        FsMetaEntry second = FsMetaEntry.forFile("src/b.java", 20L, 11L, 0x5678L, 6L, false);
        FsMetaPair pair = pairOf(List.of("a.txt", "src/b.java"), List.of(first, second));

        Assertions.assertEquals(2, pair.size());
        Assertions.assertEquals(1, pair.find("src/b.java").orElseThrow());
        Assertions.assertEquals(0, pair.find("a.txt").orElseThrow());
        Assertions.assertTrue(pair.find("missing.txt").isEmpty());
        Assertions.assertTrue(pair.contains("a.txt"));
        Assertions.assertEquals(0x5678L, pair.entryOrNull("src/b.java").contentHash());
        Assertions.assertNull(pair.entryOrNull("missing.txt"));
        Assertions.assertEquals("ok", pair.validation().describe());
    }

    @Test
    void aLookupVerifiesTheStoredNameRatherThanTheHash() {
        // A pair cannot be *valid* while holding two different names with one hash — validation would call
        // that name-hash-mismatch — so the interesting property is the other way round: a name the pair does
        // not list is empty even when a hash matches the queried name's prefix. `find` hashes the query,
        // narrows by hash, and then compares the stored name, so a 64-bit collision costs a comparison
        // rather than a wrong answer.
        FsMetaEntry one = FsMetaEntry.forFile("a.txt", 10L, 6L, 0x1234L, 0L, false);
        FsMetaEntry two = FsMetaEntry.forFile("b.txt", 20L, 4L, 0x5678L, 6L, false);
        FsMetaPair pair = pairOf(List.of("a.txt", "b.txt"), List.of(one, two));

        Assertions.assertTrue(pair.find("A.txt").isEmpty(), "case is not folded");
        Assertions.assertTrue(pair.find("a.txt ").isEmpty(), "the name is compared, not just its hash");
        Assertions.assertTrue(pair.find("a.tx").isEmpty());
    }

    @Test
    void anEmptySnapshotIsAUsableTrio() {
        FsMetaPair pair = pairOf(List.of(), List.of());
        Assertions.assertEquals(0, pair.size());
        Assertions.assertTrue(pair.find("anything").isEmpty());
        Assertions.assertTrue(pair.validation().usable());
        Assertions.assertEquals("ok", pair.validation().describe());
    }

    @Test
    void anUntrustedEntryIsReportedButDoesNotFailThePair() {
        FsMetaEntry future = new FsMetaEntry(1L, FsMetaHash.ofName("a.txt"), 0x11L, 1L, 0L, 5,
                FsMetaFormat.fileFlags(false) | 0x80, 0L, 0L);
        FsMetaPair pair = pairOf(List.of("a.txt"), List.of(future));

        Assertions.assertTrue(pair.validation().usable());
        Assertions.assertEquals(List.of(0), pair.validation().untrusted());
        Assertions.assertTrue(pair.untrusted(0));
        Assertions.assertFalse(pair.entry(0).usableFingerprint(),
                "§ 6: an unknown flag bit means the fingerprint is not to be trusted");
        Assertions.assertTrue(pair.validation().describe().contains("untrusted"));
    }

    @Test
    void aListingOnlyEntryHasNoFingerprintToCompare() {
        FsMetaEntry listingOnly = FsMetaEntry.listingOnly("a.txt", 0L);
        FsMetaPair pair = pairOf(List.of("a.txt"), List.of(listingOnly));

        Assertions.assertTrue(pair.validation().usable());
        Assertions.assertTrue(pair.validation().untrusted().isEmpty());
        Assertions.assertFalse(pair.entry(0).usableFingerprint());
        Assertions.assertEquals(0L, pair.entry(0).sizeBytes(), "the field is zero and must be ignored");
    }

    @Test
    void ofRefusesAnUnusablePair() {
        byte[] txt = FsMetaCodec.encodeNames(List.of("a.txt"));
        byte[] meta = FsMetaCodec.encodeEntries(List.of(FsMetaEntry.forFile("a.txt", 1L, 1L, 1L, 0L, false)));
        FsMetaConfig config = FsMetaConfig.forPublish(1, meta.length, txt.length + 1, 1L,
                FsMetaHashMode.NONE, "test/1", "", "", "");
        IllegalArgumentException failure = Assertions.assertThrows(IllegalArgumentException.class,
                () -> FsMetaPair.of(meta, txt, config));
        Assertions.assertTrue(failure.getMessage().contains("txt-size-mismatch"), failure.getMessage());
    }

    @Test
    void loadIfPresentIsNullWhenACheckoutHasNeverBeenScanned(@TempDir Path directory) throws IOException {
        Assertions.assertNull(FsMetaPair.loadIfPresent(directory));
        Files.writeString(directory.resolve(FsMetaFormat.META_FILE), "");
        Assertions.assertNull(FsMetaPair.loadIfPresent(directory), "a partial trio is the same as none");
    }

    @Test
    void loadReportsATornPublishRatherThanTrustingIt(@TempDir Path directory) throws IOException {
        // The state § 9 leaves behind when a crash lands between the data files and the commit record:
        // files.txt and files.meta are new, files.json still describes the previous generation.
        byte[] txt = FsMetaCodec.encodeNames(List.of("a.txt", "b.txt"));
        byte[] meta = FsMetaCodec.encodeEntries(List.of(
                FsMetaEntry.forFile("a.txt", 1L, 1L, 1L, 0L, false),
                FsMetaEntry.forFile("b.txt", 1L, 1L, 1L, 6L, false)));
        FsMetaConfig stale = FsMetaConfig.forPublish(1, 64, 6, 1L,
                FsMetaHashMode.NONE, "test/1", "", "", "");
        Files.write(directory.resolve(FsMetaFormat.TXT_FILE), txt);
        Files.write(directory.resolve(FsMetaFormat.META_FILE), meta);
        Files.writeString(directory.resolve(FsMetaFormat.JSON_FILE), stale.toJson());

        FsMetaLoad load = FsMetaPair.load(directory);
        Assertions.assertFalse(load.ok());
        Assertions.assertEquals(FsMetaVerdict.META_SIZE_MISMATCH, load.verdict());
        Assertions.assertTrue(load.describe().contains("meta-size-mismatch"), load.describe());
    }

    @Test
    void aDocumentThatIsNotJsonAtAllIsAnUnsupportedFormat(@TempDir Path directory) throws IOException {
        Files.write(directory.resolve(FsMetaFormat.META_FILE), new byte[0]);
        Files.write(directory.resolve(FsMetaFormat.TXT_FILE), new byte[0]);
        Files.writeString(directory.resolve(FsMetaFormat.JSON_FILE), "{not json");

        FsMetaLoad load = FsMetaPair.load(directory);
        Assertions.assertEquals(FsMetaVerdict.UNSUPPORTED_FORMAT, load.verdict());
        Assertions.assertFalse(load.ok());
    }

    @Test
    void namesInFormatOrderIsTheOrderAWriterPublishes() {
        FsMetaEntry first = FsMetaEntry.forFile("src/b.java", 1L, 1L, 1L, 0L, false);
        FsMetaEntry second = FsMetaEntry.forFile("a.txt", 1L, 1L, 1L, 11L, false);
        FsMetaPair pair = pairOf(List.of("src/b.java", "a.txt"), List.of(first, second));
        Assertions.assertEquals(List.of("a.txt", "src/b.java"), pair.namesInFormatOrder());
        Assertions.assertEquals(List.of("src/b.java", "a.txt"), pair.names(),
                "the pair reports the order it was written in, which is not necessarily sorted");
    }
}