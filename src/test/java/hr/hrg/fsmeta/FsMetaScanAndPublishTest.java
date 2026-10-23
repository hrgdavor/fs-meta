// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;
import java.util.List;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * The writer's half end to end: scan a real directory, publish, read it back, and diff two generations —
 * plus the scan rules that decide what a trio describes.
 */
class FsMetaScanAndPublishTest {

    @TempDir
    Path root;

    private Path trio() {
        return root.resolve(FsMetaFormat.DIRECTORY_NAME);
    }

    private void write(String relative, String content) throws IOException {
        Path file = root.resolve(relative);
        Files.createDirectories(file.getParent());
        Files.writeString(file, content, StandardCharsets.UTF_8);
    }

    private void writeBytes(String relative, byte[] content) throws IOException {
        Path file = root.resolve(relative);
        Files.createDirectories(file.getParent());
        Files.write(file, content);
    }

    private void touch(String relative, long millis) throws IOException {
        Files.setLastModifiedTime(root.resolve(relative), FileTime.fromMillis(millis));
    }

    private FsMetaLoad publish() throws IOException {
        return FsMetaWriter.publish(trio(), FsMetaScanner.scan(root, FsMetaScanOptions.defaults()),
                FsMetaHashMode.TEXT, "test/1", root.toString());
    }

    private static List<String> namesOf(FsMetaLoad load) {
        return load.pair().names();
    }

    @Test
    void aScanPublishesATrioAnyReaderCanUse() throws IOException {
        write("a.txt", "hello\n");
        write("src/b.java", "class B {}\n");

        List<FsMetaFile> files = FsMetaScanner.scan(root, FsMetaScanOptions.defaults());
        Assertions.assertEquals(List.of("a.txt", "src/b.java"),
                files.stream().map(FsMetaFile::name).toList(), "the scan sorts by the format's name order");

        FsMetaLoad first = publish();
        Assertions.assertTrue(first.ok(), first.describe());
        Assertions.assertEquals(1L, first.config().generation());
        Assertions.assertEquals(2, first.pair().size());
        Assertions.assertEquals(FsMetaFormat.VERSION, first.config().version());
        Assertions.assertEquals(FsMetaHashMode.TEXT.wire(), first.config().hashNormalize());

        FsMetaEntry entry = first.pair().entryOrNull("a.txt");
        Assertions.assertEquals(FsMetaHash.of(FsMetaHash.utf8("hello\n")), entry.contentHash());
        Assertions.assertEquals(6L, entry.sizeBytes());
        Assertions.assertTrue(entry.hashLf(), "text mode normalises, and the entry says so");
        Assertions.assertTrue(entry.usableFingerprint());

        // The trio reads back from disk exactly as it was published, and the generation advances.
        FsMetaLoad reloaded = FsMetaPair.loadOrFail(trio());
        Assertions.assertTrue(reloaded.ok(), reloaded.describe());
        Assertions.assertEquals(1L, reloaded.config().generation());
        FsMetaLoad second = publish();
        Assertions.assertEquals(2L, second.config().generation());
        Assertions.assertEquals(first.config().created(), second.config().created(),
                "created is carried over; updated moves");
    }

    @Test
    void theTrioDirectoryIsNeverPartOfItsOwnSnapshot() throws IOException {
        write("a.txt", "hello\n");
        publish();
        Assertions.assertTrue(Files.isRegularFile(trio().resolve(FsMetaFormat.META_FILE)));

        FsMetaLoad again = publish();
        Assertions.assertEquals(List.of("a.txt"), namesOf(again),
                "a scan must not index the trio it is about to replace");
    }

    @Test
    void twoGenerationsDiffIntoTheKindsTheFormatDefines() throws IOException {
        write("modify.txt", "one\n");
        write("touch.txt", "same\n");
        write("gone.txt", "bye\n");
        touch("modify.txt", 1_700_000_000_000L);
        touch("touch.txt", 1_700_000_000_000L);
        touch("gone.txt", 1_700_000_000_000L);
        FsMetaPair before = publish().pair();

        write("modify.txt", "two\n");
        write("fresh.txt", "new\n");
        Files.delete(root.resolve("gone.txt"));
        touch("touch.txt", 1_700_000_100_000L);   // same content, later mtime
        touch("modify.txt", 1_700_000_100_000L);
        FsMetaPair after = publish().pair();

        List<FsMetaDiff.Change> changes = FsMetaDiff.between(before, after);
        Assertions.assertEquals(List.of("+ fresh.txt", "- gone.txt", "M modify.txt", "T touch.txt"),
                changes.stream().map(FsMetaDiff.Change::line).toList(),
                "added, modified, removed and touched, sorted by name");
        Assertions.assertEquals(FsMetaDiff.Kind.TOUCHED,
                changes.stream().filter(change -> change.name().equals("touch.txt")).findFirst().orElseThrow().kind());
        Assertions.assertEquals(0, FsMetaDiff.between(after, after).size(), "a pair does not differ from itself");
    }

    @Test
    void theTextModeMakesCrlfAndLfAgreeAndFlagsBoth() throws IOException {
        write("crlf.txt", "line1\r\nline2\r\n");
        write("lf.txt", "line1\nline2\n");
        writeBytes("binary.bin", new byte[] {1, 2, 0, 3});

        FsMetaPair pair = publish().pair();
        FsMetaEntry crlf = pair.entryOrNull("crlf.txt");
        FsMetaEntry lf = pair.entryOrNull("lf.txt");
        FsMetaEntry binary = pair.entryOrNull("binary.bin");

        Assertions.assertEquals(lf.contentHash(), crlf.contentHash(),
                "the same text checked out two ways must hash the same");
        Assertions.assertTrue(crlf.hashLf() && lf.hashLf());
        Assertions.assertFalse(binary.hashLf(), "a NUL byte makes it binary, and it is hashed raw");
        Assertions.assertEquals(FsMetaHash.of(new byte[] {1, 2, 0, 3}), binary.contentHash());
    }

    @Test
    void theIgnoreListIsHonouredAndTheDefaultIsOnlyGitAndTheTrio() throws IOException {
        write("keep.txt", "keep\n");
        write(".git/objects/x", "git\n");
        write("target/out.txt", "build\n");

        List<String> defaults = FsMetaScanner.scan(root, FsMetaScanOptions.defaults()).stream()
                .map(FsMetaFile::name).toList();
        Assertions.assertEquals(List.of("keep.txt", "target/out.txt"), defaults,
                "the format's own default skips only .git and .fs-meta: a project's build layout is the "
                        + "project's business (DEC-044's reason)");

        List<String> narrowed = FsMetaScanner.scan(root, FsMetaScanOptions.defaults().ignoring("target")).stream()
                .map(FsMetaFile::name).toList();
        Assertions.assertEquals(List.of("keep.txt"), narrowed);
    }

    @Test
    void anEmptyDirectoryIsAValidEmptySnapshot() throws IOException {
        FsMetaLoad load = publish();
        Assertions.assertTrue(load.ok(), load.describe());
        Assertions.assertEquals(0, load.pair().size());
        Assertions.assertEquals(0L, load.config().count());
        Assertions.assertEquals(0L, load.config().metaBytes());
        Assertions.assertEquals("ok", load.pair().validation().describe());
        Assertions.assertTrue(Files.readAllBytes(trio().resolve(FsMetaFormat.META_FILE)).length == 0);
    }

    @Test
    void aSymbolicLinkIsNotListed() throws IOException {
        write("real.txt", "real\n");
        Path link = root.resolve("link.txt");
        try {
            Files.createSymbolicLink(link, root.resolve("real.txt"));
        } catch (IOException | UnsupportedOperationException needsPrivilege) {
            org.junit.jupiter.api.Assumptions.assumeTrue(false,
                    "this platform cannot create a symlink without elevation: " + needsPrivilege.getMessage());
        }
        List<String> names = FsMetaScanner.scan(root, FsMetaScanOptions.defaults()).stream()
                .map(FsMetaFile::name).toList();
        Assertions.assertEquals(List.of("real.txt"), names,
                "a symlink is skipped rather than reported as its target's content (§ 15)");
    }

    @Test
    void scanFileRecordsWhatAScanWould() throws IOException {
        write("a.txt", "hello\n");
        write("sub/b.txt", "b\n");
        FsMetaScanOptions options = FsMetaScanOptions.defaults();

        FsMetaFile scanned = FsMetaScanner.scan(root, options).stream()
                .filter(file -> file.name().equals("sub/b.txt")).findFirst().orElseThrow();
        FsMetaFile single = FsMetaScanner.scanFile(root, root.resolve("sub/b.txt"), options).orElseThrow();
        Assertions.assertEquals(scanned, single);

        IOException failure = Assertions.assertThrows(IOException.class,
                () -> FsMetaScanner.scanFile(root, root.resolve(".."), options));
        Assertions.assertTrue(failure.getMessage().contains("not inside the scan root"), failure.getMessage());

        Assertions.assertTrue(FsMetaScanner.scanFile(root, root.resolve("sub"), options).isEmpty(),
                "a directory is not something a trio lists");
    }

    @Test
    void gitignoreFilesAreHonouredAndCountAsFilesRules() throws IOException {
        write(".gitignore", "*.log\nout/\n!keep.log\n");
        write("debug.log", "ignored\n");
        write("keep.log", "re-included\n");
        write("out/built.txt", "ignored\n");
        write("src/code.java", "kept\n");

        List<String> names = FsMetaScanner.scan(root, FsMetaScanOptions.defaults()).stream()
                .map(FsMetaFile::name).toList();
        Assertions.assertEquals(List.of(".gitignore", "keep.log", "src/code.java"), names,
                "a .gitignore is itself a file the trio lists, and it decides the rest");

        Assertions.assertTrue(FsMetaScanner.scanFile(root, root.resolve("debug.log"),
                FsMetaScanOptions.defaults()).isEmpty(),
                "a watcher hears about an ignored file too; the answer to 'record this?' is no");
        Assertions.assertTrue(FsMetaScanner.scanFile(root, root.resolve("keep.log"),
                FsMetaScanOptions.defaults()).isPresent());
        Assertions.assertTrue(FsMetaScanner.scanFile(root, root.resolve("out/built.txt"),
                FsMetaScanOptions.defaults()).isEmpty(),
                "the directory is excluded, so nothing below it is recorded either");

        List<String> everything = FsMetaScanner.scan(root, FsMetaScanOptions.defaults().withoutGitignore()).stream()
                .map(FsMetaFile::name).toList();
        Assertions.assertEquals(List.of(".gitignore", "debug.log", "keep.log", "out/built.txt", "src/code.java"),
                everything, "--no-gitignore lists the tree as it is");
    }

    @Test
    void aListingOnlyEntryMakesADiffSayUnknownRatherThanGuess() throws IOException {
        write("a.txt", "hello\n");
        FsMetaPair before = publish().pair();

        FsMetaLoad after = FsMetaWriter.publish(trio(), List.of(FsMetaFile.listingOnly("a.txt")),
                FsMetaHashMode.TEXT, "test/1", root.toString());
        List<FsMetaDiff.Change> changes = FsMetaDiff.between(before, after.pair());
        Assertions.assertEquals(1, changes.size());
        Assertions.assertEquals(FsMetaDiff.Kind.UNKNOWN, changes.get(0).kind(),
                "§ 11: no fingerprint on one side means no conclusion");
    }
}