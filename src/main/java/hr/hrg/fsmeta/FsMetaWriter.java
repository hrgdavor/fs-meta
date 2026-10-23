// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/**
 * Publishes a generation: the one place that writes the trio, and the one place that knows the write
 * order {@code FORMAT.md} § 9 makes normative.
 *
 * <ol>
 *   <li>{@code files.txt} — temporarily, then atomically onto its name;</li>
 *   <li>{@code files.meta} — the same;</li>
 *   <li>{@code files.json} — <strong>last</strong>, because it is the commit record, and a reader that
 *       finds it older than the data files sees sizes that disagree and rescans rather than trusting a
 *       half-published generation.</li>
 * </ol>
 *
 * <p>The writer also re-reads what it wrote and returns the resulting {@link FsMetaLoad}. A publish that
 * cannot be validated back is a bug in the writer, and the cheapest way to notice one is to check it at the
 * moment it happens rather than in a consumer's later read.</p>
 */
public final class FsMetaWriter {

    private FsMetaWriter() {
    }

    /**
     * Writes the trio for {@code files} into {@code directory}.
     *
     * @param directory the trio's directory, normally {@code <root>/.fs-meta}
     * @param files     the files to describe; sorted here, as § 3 requires
     * @param mode      the writer's hash mode, recorded in the document's {@code hash.normalize}
     * @param writer    the {@code writer} field, e.g. {@code fsmeta-java/1}
     * @param root      the root the names are relative to, recorded as a local fact
     * @return the trio as it now reads back, which is validated
     */
    public static FsMetaLoad publish(
            Path directory, List<FsMetaFile> files, FsMetaHashMode mode, String writer, String root)
            throws IOException {
        List<FsMetaFile> ordered = new ArrayList<>(files);
        ordered.sort(Comparator.comparing(FsMetaFile::name, FsMetaFormat.NAME_ORDER));

        List<String> names = new ArrayList<>(ordered.size());
        for (FsMetaFile file : ordered) {
            names.add(file.name());
        }
        byte[] txt = FsMetaCodec.encodeNames(names);

        List<FsMetaEntry> entries = new ArrayList<>(ordered.size());
        long offset = 0;
        for (FsMetaFile file : ordered) {
            entries.add(file.toEntry(offset));
            offset += FsMetaCodec.utf8Length(file.name()) + 1L;
        }
        byte[] meta = FsMetaCodec.encodeEntries(entries);

        Previous previous = Previous.read(directory);
        String created = previous.created().isEmpty() ? FsMetaConfig.now() : previous.created();
        FsMetaConfig config = FsMetaConfig.forPublish(
                entries.size(),
                meta.length,
                txt.length,
                previous.generation() + 1,
                mode,
                writer,
                root,
                created,
                FsMetaConfig.now());

        Files.createDirectories(directory);
        writeAtomically(directory.resolve(FsMetaFormat.TXT_FILE), txt);
        writeAtomically(directory.resolve(FsMetaFormat.META_FILE), meta);
        writeAtomically(directory.resolve(FsMetaFormat.JSON_FILE),
                config.toJson().getBytes(StandardCharsets.UTF_8));

        return FsMetaPair.load(directory);
    }

    /**
     * Writes the three files in the order § 9 requires, each through a temporary file in the same
     * directory so the rename is atomic.
     *
     * <p>{@code force(true)} before the rename is what makes the commit record's claim survive a crash:
     * without it the rename can reach the directory before the bytes reach the disk. A file system that
     * cannot rename atomically falls back to a plain replace — recorded here rather than hidden, because
     * the window it opens is exactly the torn publish § 8's size checks exist to catch.</p>
     */
    private static void writeAtomically(Path target, byte[] content) throws IOException {
        Path temporary = target.resolveSibling(target.getFileName() + ".tmp");
        try (FileChannel channel = FileChannel.open(temporary,
                StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE)) {
            ByteBuffer buffer = ByteBuffer.wrap(content);
            while (buffer.hasRemaining()) {
                channel.write(buffer);
            }
            channel.force(true);
        }
        try {
            Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch (AtomicMoveNotSupportedException notAtomic) {
            Files.move(temporary, target, StandardCopyOption.REPLACE_EXISTING);
        }
    }

    /** What a previous generation contributes to the next one: its counter and the instant it was created. */
    private record Previous(long generation, String created) {

        private static Previous read(Path directory) {
            Path document = directory.resolve(FsMetaFormat.JSON_FILE);
            if (!Files.isRegularFile(document)) {
                return new Previous(0L, "");
            }
            try {
                FsMetaConfig config = FsMetaConfig.parse(
                        new String(Files.readAllBytes(document), StandardCharsets.UTF_8));
                return new Previous(config.generation(), config.created());
            } catch (IOException | IllegalArgumentException unreadable) {
                // A document that cannot be read is not a reason to refuse to publish: the generation
                // restarts at 1, and the trio's previous state was unusable anyway.
                return new Previous(0L, "");
            }
        }
    }
}
