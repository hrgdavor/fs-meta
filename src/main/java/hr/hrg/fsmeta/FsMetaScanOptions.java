// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.util.LinkedHashSet;
import java.util.Set;

import hr.hrg.gitignore.GitIgnoreFile;
import hr.hrg.gitignore.GitIgnoreRules;

/**
 * What a scan walks, and how it hashes — the two decisions that shape the trio a scan produces.
 *
 * <h3>What is not ours is a {@code .gitignore} file, read per directory</h3>
 * <p>{@link #respectGitignore()} is on by default, and the walk reads a {@code .gitignore} in every
 * directory it enters ({@link GitIgnoreFile} and {@link GitIgnoreRules} hold the semantics, and
 * {@code conformance/gitignore-vectors.json} pins them across ports). That is this repository's own answer
 * to "which files are ours": a hand-written skip list is a promise somebody has to remember to keep, and
 * its failure is a silently incomplete index rather than an error (DEC-044). A project whose ignore rules
 * are not in a {@code .gitignore} — or a caller that wants everything listed regardless — turns this off
 * and passes explicit {@linkplain #ignoredDirectoryNames() directory names} instead.</p>
 *
 * <p>The two names in {@link #DEFAULT_IGNORED} are skipped whatever else is configured: {@code .git} is
 * git's own directory, and {@code .fs-meta} is the trio, which must never index itself.</p>
 *
 * @param hashMode              how content is hashed; {@link FsMetaHashMode#TEXT} by default, so a CRLF and
 *                              an LF checkout of the same sources agree while images are left alone
 * @param ignoredDirectoryNames directory names not entered, anywhere in the tree, in addition to what
 *                              {@code .gitignore} says
 * @param respectGitignore      whether {@code .gitignore} files in the tree are read and honoured
 */
public record FsMetaScanOptions(
        FsMetaHashMode hashMode,
        Set<String> ignoredDirectoryNames,
        boolean respectGitignore) {

    /** The names every scan skips: `.git` is git's own, and `.fs-meta` is the trio itself. */
    public static final Set<String> DEFAULT_IGNORED =
            Set.of(".git", FsMetaFormat.DIRECTORY_NAME);

    /**
     * The defaults: text-aware hashing, {@code .gitignore} honoured, and only `.git` / `.fs-meta` skipped by
     * name.
     *
     * <p>{@link FsMetaHashMode#TEXT} rather than {@code none} because the point of a shared snapshot is that
     * two checks of the same code agree: a CRLF checkout and an LF one hash the same source the same way,
     * and a binary is still hashed raw.</p>
     */
    public static FsMetaScanOptions defaults() {
        return new FsMetaScanOptions(FsMetaHashMode.TEXT, DEFAULT_IGNORED, true);
    }

    /** The same options with one more directory name skipped. */
    public FsMetaScanOptions ignoring(String directoryName) {
        LinkedHashSet<String> merged = new LinkedHashSet<>(ignoredDirectoryNames);
        merged.add(directoryName);
        return new FsMetaScanOptions(hashMode, Set.copyOf(merged), respectGitignore);
    }

    /** The same options with a different hash mode. */
    public FsMetaScanOptions hashing(FsMetaHashMode mode) {
        return new FsMetaScanOptions(mode, ignoredDirectoryNames, respectGitignore);
    }

    /** The same options with {@code .gitignore} files not read: every file under the root is listed. */
    public FsMetaScanOptions withoutGitignore() {
        return new FsMetaScanOptions(hashMode, ignoredDirectoryNames, false);
    }

    /** The same options with {@code .gitignore} files honoured. */
    public FsMetaScanOptions withGitignore() {
        return new FsMetaScanOptions(hashMode, ignoredDirectoryNames, true);
    }
}