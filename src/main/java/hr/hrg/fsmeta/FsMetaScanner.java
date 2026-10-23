// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.io.IOException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Optional;

import hr.hrg.gitignore.GitIgnoreFile;
import hr.hrg.gitignore.GitIgnoreRules;

/**
 * Walks a codebase folder and produces the files a trio will describe.
 *
 * <p>This is the one expensive operation in the format: it reads every listed file to hash it, which is
 * exactly the cost the trio exists to let other tools avoid. A watcher runs it once (or applies
 * {@link #scanFile} to the paths a change event named) and publishes the result; every other tool reads 64
 * bytes per file instead.</p>
 *
 * <h3>What is listed</h3>
 * <ul>
 *   <li><strong>Regular files only.</strong> A symbolic link is skipped rather than followed or recorded: a
 *       link's identity is both the link and its target, and a v1 entry has no field for the link
 *       ({@code FORMAT.md} § 15). Directories are structure, not content — a reader derives them from the
 *       names.</li>
 *   <li><strong>{@code .git} and {@code .fs-meta} never.</strong> The first is git's own directory, the
 *       second is the trio, which must not index itself.</li>
 *   <li><strong>A {@code .gitignore} in any directory is honoured</strong> ({@link FsMetaScanOptions}), and
 *       an ignored directory is not entered — git's rule, and where the speed comes from.</li>
 *   <li><strong>An unreadable path fails the scan</strong> rather than being left out silently: a trio that
 *       omits files without saying so is a wrong answer, and a scan that cannot see part of the tree must
 *       say so instead.</li>
 * </ul>
 */
public final class FsMetaScanner {

    private FsMetaScanner() {
    }

    /** Every regular file under {@code root} that the options do not ignore, in the format's name order. */
    public static List<FsMetaFile> scan(Path root, FsMetaScanOptions options) throws IOException {
        Path base = root.toAbsolutePath().normalize();
        if (!Files.isDirectory(base)) {
            throw new IOException("not a directory to scan: " + base);
        }
        List<FsMetaFile> files = new ArrayList<>();
        GitIgnoreRules rules = new GitIgnoreRules();

        Files.walkFileTree(base, new SimpleFileVisitor<Path>() {

            @Override
            public FileVisitResult preVisitDirectory(Path directory, BasicFileAttributes attributes)
                    throws IOException {
                String relative = relativeName(base, directory);
                if (!directory.equals(base)
                        && options.ignoredDirectoryNames().contains(directory.getFileName().toString())) {
                    return FileVisitResult.SKIP_SUBTREE;
                }
                if (options.respectGitignore()) {
                    // The directory is judged by the rules that apply where it sits: its own .gitignore
                    // governs what is inside it and never the directory itself (git's scope rule).
                    if (rules.isIgnored(relative, true)) {
                        return FileVisitResult.SKIP_SUBTREE;
                    }
                    rules.push(GitIgnoreFile.readOrEmpty(directory, relative));
                }
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult visitFile(Path file, BasicFileAttributes attributes) throws IOException {
                if (!attributes.isRegularFile()) {
                    return FileVisitResult.CONTINUE;      // a symlink is not listed (§ 15)
                }
                if (options.respectGitignore() && rules.isIgnored(relativeName(base, file), false)) {
                    return FileVisitResult.CONTINUE;
                }
                files.add(of(base, file, attributes, options));
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult postVisitDirectory(Path directory, IOException failure) throws IOException {
                if (options.respectGitignore()) {
                    rules.pop();
                }
                if (failure != null) {
                    throw failure;
                }
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult visitFileFailed(Path file, IOException failure) throws IOException {
                // Not swallowed: see the class javadoc — an incomplete trio is worse than a failed scan.
                throw failure;
            }
        });

        files.sort(Comparator.comparing(FsMetaFile::name, FsMetaFormat.NAME_ORDER));
        return files;
    }

    /**
     * One file, as {@link #scan} would record it — what an incremental update needs for a path a watcher
     * reported as changed.
     *
     * <p>Empty when the file is one the scan would not list: not a regular file, inside a {@code .git} or
     * {@code .fs-meta} directory, or excluded by a {@code .gitignore} on the way to it. A watcher hears about
     * events in ignored directories too, and the answer to "record this?" is then "no", not an error.</p>
     *
     * @throws IOException when the path is not inside {@code root}
     */
    public static Optional<FsMetaFile> scanFile(Path root, Path file, FsMetaScanOptions options)
            throws IOException {
        Path base = root.toAbsolutePath().normalize();
        Path target = file.toAbsolutePath().normalize();
        if (!target.startsWith(base)) {
            throw new IOException(target + " is not inside the scan root " + base);
        }
        if (!Files.isRegularFile(target)) {
            return Optional.empty();
        }

        // Rebuild the rules that apply where the file sits: its ancestors' .gitignore files, outermost first.
        GitIgnoreRules rules = new GitIgnoreRules();
        List<Path> ancestors = new ArrayList<>();
        for (Path directory = target.getParent(); directory != null && directory.startsWith(base);
                directory = directory.getParent()) {
            ancestors.add(directory);
        }
        for (int index = ancestors.size() - 1; index >= 0; index--) {
            Path directory = ancestors.get(index);
            String relative = relativeName(base, directory);
            if (!directory.equals(base)
                    && options.ignoredDirectoryNames().contains(directory.getFileName().toString())) {
                return Optional.empty();
            }
            if (options.respectGitignore()) {
                if (rules.isIgnored(relative, true)) {
                    return Optional.empty();
                }
                rules.push(GitIgnoreFile.readOrEmpty(directory, relative));
            }
        }
        if (options.respectGitignore() && rules.isIgnored(relativeName(base, target), false)) {
            return Optional.empty();
        }
        return Optional.of(of(base, target, Files.readAttributes(target, BasicFileAttributes.class), options));
    }

    /** The entry a single file becomes: its relative name, its stat fields and its content hash. */
    private static FsMetaFile of(
            Path base, Path file, BasicFileAttributes attributes, FsMetaScanOptions options) throws IOException {
        byte[] content = Files.readAllBytes(file);
        FsMetaHash.Hashed hashed = FsMetaHash.hash(content, options.hashMode());
        return FsMetaFile.hashed(
                relativeName(base, file),
                attributes.lastModifiedTime().to(java.util.concurrent.TimeUnit.NANOSECONDS),
                attributes.size(),
                hashed.hash(),
                hashed.hashLf());
    }

    /** A path's name relative to the walk root, always `/`-separated, the way an entry stores it (§ 3). */
    private static String relativeName(Path base, Path path) {
        return path.equals(base) ? "" : base.relativize(path).toString().replace('\\', '/');
    }
}