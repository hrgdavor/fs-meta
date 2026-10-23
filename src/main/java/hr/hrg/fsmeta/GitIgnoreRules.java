// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/**
 * The {@code .gitignore} files that apply at one point of a walk — git's precedence, in a stack.
 *
 * <p>A walk pushes a directory's {@code .gitignore} when it enters the directory and pops it when it
 * leaves, so the stack at any moment is exactly the set of files that govern the path being visited. The
 * decision rule is git's: the <strong>deepest</strong> file that has an opinion wins, and within one file
 * the <strong>last</strong> matching pattern wins — which is what makes a nested {@code !keep.tmp} able to
 * re-include a file that an outer {@code *.tmp} excluded.</p>
 *
 * <p>{@link #isIgnored} answers "would git call this not ours?", and it is the question the scanner asks
 * before it descends into a directory. A directory that is ignored is <strong>not entered</strong>, which is
 * both git's rule — a file inside an excluded directory cannot be re-included — and where the speed of a
 * real {@code .gitignore}-driven walk comes from.</p>
 */
public final class GitIgnoreRules {

    private final List<GitIgnoreFile> stack = new ArrayList<>();

    /** Enters a directory: its rules (an empty file when it has none) apply from here on. */
    public void push(GitIgnoreFile file) {
        stack.add(file);
    }

    /** Leaves the directory most recently pushed. */
    public void pop() {
        if (!stack.isEmpty()) {
            stack.remove(stack.size() - 1);
        }
    }

    /** How many {@code .gitignore} files currently apply — the walk's depth, for a test or a diagnostic. */
    public int depth() {
        return stack.size();
    }

    /**
     * The decision the deepest applicable {@code .gitignore} makes about a path relative to the walk root.
     *
     * @return empty when no file has an opinion, which is not the same as "included": an outer file may
     *         still exclude it — the stack is consulted deepest first precisely so that is a decision and
     *         not an accident
     */
    public Optional<Boolean> decide(String relativePath, boolean isDirectory) {
        for (int index = stack.size() - 1; index >= 0; index--) {
            Optional<Boolean> decision = stack.get(index).decide(relativePath, isDirectory);
            if (decision.isPresent()) {
                return decision;
            }
        }
        return Optional.empty();
    }

    /** Whether the deepest applicable {@code .gitignore} excludes the path. */
    public boolean isIgnored(String relativePath, boolean isDirectory) {
        return decide(relativePath, isDirectory).orElse(false);
    }
}