// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * The command line: what a shell or a build step gets, and the exit codes it can branch on.
 *
 * <p>The CLI is thin over the tested API, so this is a smoke test with three specific jobs — the commands
 * are wired, the exit codes are the documented ones, and {@code repair} actually puts a broken pair back
 * together.</p>
 */
class FsMetaCliTest {

    @TempDir
    Path root;

    /** A second temp directory, so a copy of a trio never lands inside the tree being scanned. */
    @TempDir
    Path scratch;

    private Path trio() {
        return root.resolve(FsMetaFormat.DIRECTORY_NAME);
    }

    /** One CLI invocation: its exit code and everything it printed. */
    private record Run(int code, String out, String err) {

        String all() {
            return out + err;
        }
    }

    private Run fsmeta(String... args) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ByteArrayOutputStream err = new ByteArrayOutputStream();
        int code;
        try (PrintStream outStream = new PrintStream(out, true, StandardCharsets.UTF_8);
                PrintStream errStream = new PrintStream(err, true, StandardCharsets.UTF_8)) {
            code = new FsMetaCli(outStream, errStream).run(args);
        }
        return new Run(code, out.toString(StandardCharsets.UTF_8), err.toString(StandardCharsets.UTF_8));
    }

    private void write(String relative, String content) throws IOException {
        Path file = root.resolve(relative);
        Files.createDirectories(file.getParent());
        Files.writeString(file, content, StandardCharsets.UTF_8);
    }

    @Test
    void scansVerifiesListsAndQueries() throws IOException {
        write("a.txt", "hello\n");
        write("src/b.java", "class B {}\n");

        Run scan = fsmeta("scan", "--root", root.toString());
        Assertions.assertEquals(0, scan.code(), scan.all());
        Assertions.assertTrue(scan.out().contains("scanned 2 file(s)"), scan.out());
        Assertions.assertTrue(scan.out().contains("generation 1"), scan.out());

        Assertions.assertEquals(0, fsmeta("verify", "--dir", trio().toString()).code());
        Run names = fsmeta("names", "--dir", trio().toString());
        Assertions.assertEquals("a.txt\nsrc/b.java\n", names.out());

        Run query = fsmeta("query", "src/b.java", "--dir", trio().toString());
        Assertions.assertEquals(0, query.code(), query.all());
        Assertions.assertTrue(query.out().startsWith("src/b.java\t"), query.out());
        Assertions.assertTrue(query.out().contains(FsMetaHash.hex(FsMetaHash.of(FsMetaHash.utf8("class B {}\n")))),
                query.out());

        Run missing = fsmeta("query", "nope.txt", "--dir", trio().toString());
        Assertions.assertEquals(1, missing.code());
        Assertions.assertTrue(missing.err().contains("is not listed"), missing.err());

        Run dump = fsmeta("dump", "--dir", trio().toString());
        Assertions.assertEquals(2, dump.out().lines().count(), dump.out());
    }

    @Test
    void reportsAMissingTrioRatherThanPretending() {
        Run verify = fsmeta("verify", "--dir", root.resolve("nowhere").toString());
        Assertions.assertEquals(1, verify.code());
        Assertions.assertTrue(verify.err().contains("no complete fs-meta trio"), verify.err());
    }

    @Test
    void refusesAMisusedInvocationWithTheUsageText() {
        Run none = fsmeta();
        Assertions.assertEquals(2, none.code());
        Assertions.assertTrue(none.err().contains("usage: fsmeta"), none.err());

        Run unknown = fsmeta("frobnicate");
        Assertions.assertEquals(2, unknown.code());

        Run missingValue = fsmeta("verify", "--dir");
        Assertions.assertEquals(2, missingValue.code());
        Assertions.assertTrue(missingValue.err().contains("needs a value"), missingValue.err());

        Assertions.assertEquals(2, fsmeta("scan", "--root", root.toString(), "--normalize", "md5").code());
    }

    @Test
    void diffsTwoGenerationsForAScript() throws IOException {
        write("a.txt", "one\n");
        Assertions.assertEquals(0, fsmeta("scan", "--root", root.toString()).code());
        Path first = scratch.resolve("first");
        Files.createDirectories(first);
        Files.copy(trio().resolve(FsMetaFormat.META_FILE), first.resolve(FsMetaFormat.META_FILE));
        Files.copy(trio().resolve(FsMetaFormat.TXT_FILE), first.resolve(FsMetaFormat.TXT_FILE));
        Files.copy(trio().resolve(FsMetaFormat.JSON_FILE), first.resolve(FsMetaFormat.JSON_FILE));

        write("a.txt", "two\n");
        write("b.txt", "new\n");
        Assertions.assertEquals(0, fsmeta("scan", "--root", root.toString()).code());

        Run diff = fsmeta("diff", first.toString(), trio().toString());
        Assertions.assertEquals(0, diff.code(), diff.all());
        Assertions.assertTrue(diff.out().contains("+ b.txt"), diff.out());
        Assertions.assertTrue(diff.out().contains("M a.txt"), diff.out());
        Assertions.assertTrue(diff.out().contains("1 added, 1 modified"), diff.out());
    }

    @Test
    void repairsAPairWhoseEntriesAndNamesGotOutOfStep() throws IOException {
        write("a.txt", "hello\n");
        write("b.txt", "bye\n");
        Assertions.assertEquals(0, fsmeta("scan", "--root", root.toString()).code());

        byte[] published = Files.readAllBytes(trio().resolve(FsMetaFormat.META_FILE));
        // Give each entry the other's name offset and length, leaving files.txt alone: every offset now
        // points at the other name, which is the state § 10 exists for. (Reordering the entries would NOT
        // break the pairing — an offset travels with its entry.)
        byte[] scrambled = published.clone();
        int entrySize = FsMetaFormat.ENTRY_SIZE;
        int nameSlice = 12;   // nameOffset (8) + nameLength (4); the flags word stays with its entry
        System.arraycopy(published, 0 * entrySize + FsMetaFormat.OFFSET_NAME_OFFSET,
                scrambled, 1 * entrySize + FsMetaFormat.OFFSET_NAME_OFFSET, nameSlice);
        System.arraycopy(published, 1 * entrySize + FsMetaFormat.OFFSET_NAME_OFFSET,
                scrambled, 0 * entrySize + FsMetaFormat.OFFSET_NAME_OFFSET, nameSlice);
        Files.write(trio().resolve(FsMetaFormat.META_FILE), scrambled);

        // § 8 checks the whole-file hash before any entry, so a hand-edited files.meta must also update the
        // document's meta.wyhash to describe the bytes being presented. Otherwise the trio is rejected as a
        // torn publish (meta-hash-mismatch) and the pairing is never examined — which is the correct verdict
        // for the wrong experiment.
        Path document = trio().resolve(FsMetaFormat.JSON_FILE);
        String json = Files.readString(document, StandardCharsets.UTF_8);
        String previousHash = FsMetaConfig.parse(json).metaWyhash();
        Files.writeString(document,
                json.replace(previousHash, FsMetaHash.hex(FsMetaHash.of(scrambled))),
                StandardCharsets.UTF_8);

        Run verify = fsmeta("verify", "--dir", trio().toString());
        Assertions.assertEquals(1, verify.code());
        Assertions.assertTrue(verify.out().contains("name-hash-mismatch"), verify.all());

        Run dryRun = fsmeta("repair", "--dir", trio().toString(), "--dry-run");
        Assertions.assertEquals(0, dryRun.code(), dryRun.all());
        Assertions.assertTrue(dryRun.out().contains("entry 0 -> a.txt"), dryRun.out());

        Run repair = fsmeta("repair", "--dir", trio().toString());
        Assertions.assertEquals(0, repair.code(), repair.all());
        Assertions.assertTrue(repair.out().contains("repaired 2 entry/entries"), repair.out());

        Assertions.assertEquals(0, fsmeta("verify", "--dir", trio().toString()).code());
        Assertions.assertArrayEquals(published, Files.readAllBytes(trio().resolve(FsMetaFormat.META_FILE)),
                "the repaired pair is byte-identical to the one before the corruption, because the names "
                        + "were already in format order");
        Assertions.assertEquals(2L, FsMetaPair.loadOrFail(trio()).config().generation(),
                "a repair is a publish, so the generation moves");
    }

    @Test
    void aRepairSaysSoWhenThereIsNothingToRepair() throws IOException {
        write("a.txt", "hello\n");
        Assertions.assertEquals(0, fsmeta("scan", "--root", root.toString()).code());
        Run repair = fsmeta("repair", "--dir", trio().toString());
        Assertions.assertEquals(0, repair.code(), repair.all());
        Assertions.assertTrue(repair.out().contains("nothing to repair"), repair.out());
    }

    @Test
    void namesAreOrderedAsTheFormatRequires() throws IOException {
        // Not `A.txt` beside `a.txt`: this test runs on file systems that are case-insensitive, where those
        // are one file. The byte-order rule itself is pinned in FsMetaCodecTest.
        write("b.txt", "b\n");
        write("a.txt", "a\n");
        write("Z.txt", "Z\n");
        Assertions.assertEquals(0, fsmeta("scan", "--root", root.toString()).code());
        Assertions.assertEquals(List.of("Z.txt", "a.txt", "b.txt"),
                fsmeta("names", "--dir", trio().toString()).out().lines().toList(),
                "uppercase sorts before lowercase, because 0x5A is below 0x61");
    }
}