// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.regex.Pattern;

/**
 * One {@code .gitignore} file's patterns, parsed once and matched the way {@code git} matches them.
 *
 * <p>This is deliberately not "a glob library". A trio describes the files a project considers ours, and
 * the definition of "not ours" in this repository — and in every project that would use {@code fs-meta} —
 * is a {@code .gitignore} file, read per directory (the reasoning is DEC-044's: a hand-written skip list is
 * a promise somebody has to remember to keep). So the semantics below are git's, and the shared vectors in
 * {@code conformance/gitignore-vectors.json} pin them so that the Java, Bun and (later) Zig walks agree
 * file for file.</p>
 *
 * <h3>The rules that are easy to get wrong, and are the reason this class is tested</h3>
 * <ul>
 *   <li><strong>Scope.</strong> A file's patterns apply only to paths <em>below</em> the directory that
 *       holds it; a path that is not under {@link #relativeDirectory()} can never match. That is also why a
 *       directory's own {@code .gitignore} cannot exclude the directory itself.</li>
 *   <li><strong>Anchoring.</strong> A pattern with a separator at the start or in the middle is relative to
 *       the {@code .gitignore}'s own directory; otherwise it matches at any depth (a basename match).</li>
 *   <li><strong>The last matching pattern wins</strong>, so {@code !keep.log} after {@code *.log}
 *       re-includes. Deeper files beat shallower ones — that is {@link GitIgnoreRules}' job, not this
 *       class's.</li>
 *   <li><strong>A trailing slash means directories only</strong>, and git also reports a file inside such a
 *       directory as ignored — which is what makes pruning a directory equivalent to ignoring everything
 *       below it.</li>
 *   <li><strong>Negation cannot resurrect a file inside an ignored directory</strong>, because the walk never
 *       enters it. {@link GitIgnoreRules} and the scanner state that as a rule rather than leaving it to be
 *       discovered.</li>
 * </ul>
 *
 * <p>Matching is <strong>case-sensitive</strong> on every platform, which is a deliberate choice over git's
 * {@code core.ignorecase} behaviour: a trio is written on one machine and read on another, and the ports
 * must agree with each other before they agree with a particular file system. The vectors pin it.</p>
 */
public final class GitIgnoreFile {

    /** The file name a walk reads per directory. */
    public static final String FILE_NAME = ".gitignore";

    private final String relativeDirectory;
    private final List<Rule> rules;

    private GitIgnoreFile(String relativeDirectory, List<Rule> rules) {
        this.relativeDirectory = relativeDirectory;
        this.rules = rules;
    }

    /**
     * Parses the text of a {@code .gitignore} that lives in {@code relativeDirectory} (empty for the walk
     * root, otherwise a {@code /}-separated path with no trailing slash).
     */
    public static GitIgnoreFile parse(String relativeDirectory, String text) {
        String directory = relativeDirectory == null ? "" : relativeDirectory;
        while (directory.endsWith("/")) {
            directory = directory.substring(0, directory.length() - 1);
        }
        List<Rule> rules = new ArrayList<>();
        for (String line : text.split("\n", -1)) {
            Rule rule = Rule.parse(line);
            if (rule != null) {
                rules.add(rule);
            }
        }
        return new GitIgnoreFile(directory, List.copyOf(rules));
    }

    /** Reads {@code directory/.gitignore} when it exists; empty when the directory has none. */
    public static Optional<GitIgnoreFile> read(java.nio.file.Path directory, String relativeDirectory)
            throws java.io.IOException {
        java.nio.file.Path file = directory.resolve(FILE_NAME);
        if (!java.nio.file.Files.isRegularFile(file)) {
            return Optional.empty();
        }
        return Optional.of(parse(relativeDirectory,
                new String(java.nio.file.Files.readAllBytes(file), java.nio.charset.StandardCharsets.UTF_8)));
    }

    /**
     * {@link #read} with the empty file substituted for "none" — what a walk pushes for every directory, so
     * its push/pop pairs stay balanced whether or not a directory has a {@code .gitignore}.
     */
    public static GitIgnoreFile readOrEmpty(java.nio.file.Path directory, String relativeDirectory)
            throws java.io.IOException {
        return read(directory, relativeDirectory).orElseGet(() -> parse(relativeDirectory, ""));
    }

    /** The directory this file governs, relative to the walk root ({@code ""} at the root). */
    public String relativeDirectory() {
        return relativeDirectory;
    }

    /** How many patterns the file holds, comments and blank lines excluded. */
    public int ruleCount() {
        return rules.size();
    }

    /**
     * What this file decides about {@code relativePath} (relative to the <em>walk root</em>, always
     * {@code /}-separated).
     *
     * @return {@code true} when the last matching pattern excludes it, {@code false} when the last matching
     *         pattern re-includes it, and empty when no pattern matches — which is not the same as
     *         "included", because a shallower {@code .gitignore} may still exclude it
     */
    public Optional<Boolean> decide(String relativePath, boolean isDirectory) {
        String scoped = scopedPath(relativePath);
        if (scoped == null) {
            return Optional.empty();
        }
        for (int index = rules.size() - 1; index >= 0; index--) {
            Rule rule = rules.get(index);
            if (rule.matches(scoped, isDirectory)) {
                return Optional.of(!rule.negated());
            }
        }
        return Optional.empty();
    }

    /** The path as this file sees it: {@code null} when the path is not below this file's directory. */
    private String scopedPath(String relativePath) {
        if (relativeDirectory.isEmpty()) {
            return relativePath;
        }
        String prefix = relativeDirectory + "/";
        return relativePath.startsWith(prefix) ? relativePath.substring(prefix.length()) : null;
    }

    /** One pattern: its polarity, whether it is directory-only, and its compiled form. */
    private record Rule(boolean negated, boolean directoryOnly, Pattern pattern) {

        /**
         * Parses one line: {@code null} for a blank line or a comment.
         */
        static Rule parse(String rawLine) {
            String line = stripTrailingUnescapedSpaces(rawLine);
            if (line.isEmpty() || line.charAt(0) == '#') {
                return null;
            }
            boolean negated = false;
            if (line.charAt(0) == '!') {
                negated = true;
                line = line.substring(1);
                if (line.isEmpty()) {
                    return null;
                }
            }
            boolean directoryOnly = line.endsWith("/") && !line.endsWith("\\/");
            if (directoryOnly) {
                line = line.substring(0, line.length() - 1);
            }
            boolean anchored = line.startsWith("/") || line.contains("/");
            if (line.startsWith("/")) {
                line = line.substring(1);
            }
            if (line.isEmpty()) {
                return null;
            }
            String regex = (anchored ? "" : "(?:.*/)?") + translate(line) + "$";
            return new Rule(negated, directoryOnly, Pattern.compile(regex));
        }

        /** Whether this pattern excludes {@code path} (which is already scoped to its own directory). */
        boolean matches(String path, boolean isDirectory) {
            if (directoryOnly) {
                if (isDirectory && pattern.matcher(path).matches()) {
                    return true;
                }
                // git reports a file inside an ignored directory as ignored too, so a directory-only
                // pattern matches any ancestor of the path. The walk prunes before it gets here, and a
                // caller that tests a path on its own gets the same answer.
                for (int slash = path.indexOf('/'); slash >= 0; slash = path.indexOf('/', slash + 1)) {
                    if (pattern.matcher(path.substring(0, slash)).matches()) {
                        return true;
                    }
                }
                return false;
            }
            return pattern.matcher(path).matches();
        }

        /** Trailing spaces are ignored unless they are escaped with a backslash. */
        private static String stripTrailingUnescapedSpaces(String line) {
            int end = line.length();
            while (end > 0 && line.charAt(end - 1) == ' ' && !isEscaped(line, end - 1)) {
                end--;
            }
            return line.substring(0, end);
        }

        private static boolean isEscaped(String line, int index) {
            int backslashes = 0;
            for (int i = index - 1; i >= 0 && line.charAt(i) == '\\'; i--) {
                backslashes++;
            }
            return (backslashes & 1) == 1;
        }

        /**
         * The glob-to-regex translation, {@code **} included: a leading or slash-delimited {@code **} covers
         * any number of directories, a bare {@code *} stays inside one path segment.
         */
        static String translate(String glob) {
            StringBuilder regex = new StringBuilder();
            for (int index = 0; index < glob.length(); index++) {
                char c = glob.charAt(index);
                switch (c) {
                    case '\\' -> {
                        if (index + 1 < glob.length()) {
                            regex.append(Pattern.quote(String.valueOf(glob.charAt(++index))));
                        } else {
                            regex.append("\\\\");
                        }
                    }
                    case '*' -> {
                        boolean doubleStar = index + 1 < glob.length() && glob.charAt(index + 1) == '*';
                        if (!doubleStar) {
                            regex.append("[^/]*");
                            break;
                        }
                        int first = index;
                        int second = index + 1;
                        boolean atSegmentStart = first == 0 || glob.charAt(first - 1) == '/';
                        boolean followedBySlash = second + 1 < glob.length() && glob.charAt(second + 1) == '/';
                        boolean atEnd = second + 1 == glob.length();
                        if (atSegmentStart && followedBySlash) {
                            // "**/" — zero or more directories. In the "/**/" form the preceding '/'
                            // has already been emitted, so the group slots in right after it.
                            regex.append("(?:.*/)?");
                            index = second + 1;      // consume the '/'
                        } else if (atSegmentStart && atEnd) {
                            // A trailing "/**" matches everything inside, not the directory itself: the
                            // '/' before it is already in the regex, so the path has to continue.
                            regex.append(".*");
                            index = second;
                        } else {
                            // Any other consecutive asterisks are just asterisks, and an asterisk never
                            // crosses a path separator (git's wildmatch rule).
                            regex.append("[^/]*");
                            index = second;
                        }
                    }
                    case '?' -> regex.append("[^/]");
                    case '[' -> index = appendCharacterClass(regex, glob, index);
                    default -> regex.append(Pattern.quote(String.valueOf(c)));
                }
            }
            return regex.toString();
        }

        /**
         * Translates {@code [...]} into a regex character class, returning the index of its closing bracket
         * (or of the {@code [} itself when the class is unterminated, which git also treats as a literal).
         */
        private static int appendCharacterClass(StringBuilder regex, String glob, int open) {
            int close = glob.indexOf(']', open + 1);
            if (close < 0) {
                regex.append("\\[");
                return open;
            }
            String body = glob.substring(open + 1, close);
            StringBuilder translated = new StringBuilder("[");
            int start = 0;
            if (!body.isEmpty() && (body.charAt(0) == '!' || body.charAt(0) == '^')) {
                translated.append('^');
                start = 1;
            }
            for (int i = start; i < body.length(); i++) {
                char c = body.charAt(i);
                if (c == '\\' && i + 1 < body.length()) {
                    translated.append('\\').append(body.charAt(++i));
                } else if (c == '[' || c == ']' || c == '^') {
                    translated.append('\\').append(c);
                } else {
                    translated.append(c);
                }
            }
            if (translated.length() == 1 || (translated.length() == 2 && translated.charAt(0) == '^')) {
                // An empty class matches nothing in git either; a group that never matches says that
                // without producing a regex Java would reject.
                regex.append("(?!)");
                return close;
            }
            translated.append(']');
            regex.append(translated);
            return close;
        }
    }
}