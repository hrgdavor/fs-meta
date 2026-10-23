// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * {@code fsmeta} — the command line over the same API the watcher uses.
 *
 * <p>Its purpose is that a tool does not need a JVM API to ask the format's questions: {@code names} and
 * {@code query} are what a build step or a script wants ("what is current?", "has this file changed?"), and
 * {@code scan}, {@code verify}, {@code diff} and {@code repair} are what an operator wants. The Bun
 * implementation ships the same commands, the same output and the same exit codes, so a pipeline does not
 * care which one answers — and <strong>output ends every line with LF on every platform</strong>, because a
 * tool that writes the platform's separator into a pipeline is a tool whose output differs by operating
 * system.</p>
 *
 * <pre>
 *   fsmeta scan   [--root DIR] [--dir DIR] [--ignore NAME]... [--normalize none|lf|text] [--writer NAME]
 *                 [--no-gitignore]
 *   fsmeta verify [--dir DIR]
 *   fsmeta names  [--dir DIR]
 *   fsmeta query  NAME [--dir DIR]
 *   fsmeta dump   [--dir DIR]
 *   fsmeta diff   DIR_A DIR_B
 *   fsmeta repair [--dir DIR] [--dry-run]
 * </pre>
 *
 * <p>Exit codes: 0 when the command's question was answered, 1 when the subject failed (no trio, a failing
 * verdict, a name that is not listed, a pair that cannot be repaired), 2 for a usage error.</p>
 */
public final class FsMetaCli {

    /** The {@code writer} field a trio written by this implementation carries. */
    public static final String WRITER = "fsmeta-java/1";

    private final PrintStream out;
    private final PrintStream err;

    /** A CLI writing to the given streams — what a test drives without touching {@code System.out}. */
    public FsMetaCli(PrintStream out, PrintStream err) {
        this.out = out;
        this.err = err;
    }

    /** Runs one command and returns its exit code. */
    public static void main(String[] args) {
        // UTF-8 explicitly, and not the platform's default: on Windows `System.out` is the console code page,
        // so a name with a non-ASCII character reaches a pipeline as replacement characters — measured by
        // fs-meta/check-ports.mjs, where `docs/héllo — ünïcode.md` came back as `docs/h?llo ? ?n?code.md`
        // from this port while the Bun port wrote it correctly. The Bun CLI writes UTF-8 by construction, and
        // the two must agree byte for byte.
        PrintStream out = new PrintStream(new java.io.FileOutputStream(java.io.FileDescriptor.out), true,
                StandardCharsets.UTF_8);
        PrintStream err = new PrintStream(new java.io.FileOutputStream(java.io.FileDescriptor.err), true,
                StandardCharsets.UTF_8);
        int code = new FsMetaCli(out, err).run(args);
        out.flush();
        err.flush();
        if (code != 0) {
            System.exit(code);
        }
    }

    /** Runs one command; see the class javadoc for the commands and the exit codes. */
    public int run(String[] args) {
        if (args.length == 0 || args[0].equals("--help") || args[0].equals("-h")) {
            usage();
            return args.length == 0 ? 2 : 0;
        }
        String command = args[0];
        Map<String, List<String>> options = new LinkedHashMap<>();
        List<String> positional = new ArrayList<>();
        String parsingError = parse(args, 1, options, positional);
        if (parsingError != null) {
            problem("fsmeta: " + parsingError);
            usage();
            return 2;
        }
        try {
            return switch (command) {
                case "scan" -> scan(options);
                case "verify" -> verify(options);
                case "names" -> names(options);
                case "query" -> query(options, positional);
                case "dump" -> dump(options);
                case "diff" -> diff(positional);
                case "repair" -> repair(options);
                default -> {
                    problem("fsmeta: unknown command '" + command + "'");
                    usage();
                    yield 2;
                }
            };
        } catch (IOException failure) {
            problem("fsmeta: " + failure.getMessage());
            return 1;
        }
    }

    // ------------------------------------------------------------------ commands

    private int scan(Map<String, List<String>> options) throws IOException {
        Path root = path(options, "root", Path.of("").toAbsolutePath());
        Path directory = path(options, "dir", root.resolve(FsMetaFormat.DIRECTORY_NAME));
        FsMetaScanOptions scanOptions = options.containsKey("no-gitignore")
                ? FsMetaScanOptions.defaults().withoutGitignore()
                : FsMetaScanOptions.defaults();
        for (String ignored : values(options, "ignore")) {
            scanOptions = scanOptions.ignoring(ignored);
        }
        String normalize = value(options, "normalize");
        if (normalize != null) {
            Optional<FsMetaHashMode> mode = FsMetaHashMode.fromWire(normalize);
            if (mode.isEmpty()) {
                problem("fsmeta: --normalize must be one of none, lf, text (got '" + normalize + "')");
                return 2;
            }
            scanOptions = scanOptions.hashing(mode.get());
        }
        List<FsMetaFile> files = FsMetaScanner.scan(root, scanOptions);
        String writer = value(options, "writer");
        FsMetaLoad load = FsMetaWriter.publish(
                directory,
                files,
                scanOptions.hashMode(),
                writer == null ? WRITER : writer,
                root.toAbsolutePath().normalize().toString());
        if (!load.ok()) {
            problem("fsmeta: the trio just written does not validate: " + load.describe());
            return 1;
        }
        line("scanned " + files.size() + " file(s) from " + root.toAbsolutePath().normalize()
                + " into " + directory + " (generation " + load.config().generation() + ")");
        return 0;
    }

    private int verify(Map<String, List<String>> options) throws IOException {
        Path directory = trioDirectory(options);
        FsMetaLoad load = FsMetaPair.loadIfPresent(directory);
        if (load == null) {
            problem("fsmeta: no complete fs-meta trio in " + directory);
            return 1;
        }
        line(load.describe());
        return load.ok() ? 0 : 1;
    }

    private int names(Map<String, List<String>> options) throws IOException {
        FsMetaLoad load = requireTrio(options);
        if (!load.ok()) {
            return 1;
        }
        for (String name : load.pair().names()) {
            line(name);
        }
        return 0;
    }

    private int query(Map<String, List<String>> options, List<String> positional) throws IOException {
        if (positional.isEmpty()) {
            problem("fsmeta: query needs a NAME");
            return 2;
        }
        String name = positional.get(0);
        FsMetaLoad load = requireTrio(options);
        if (!load.ok()) {
            return 1;
        }
        var index = load.pair().find(name);
        if (index.isEmpty()) {
            problem("fsmeta: '" + name + "' is not listed in generation "
                    + load.config().generation() + " (it is new, deleted, or not scanned)");
            return 1;
        }
        line(load.pair().entry(index.getAsInt()).format(name));
        return 0;
    }

    private int dump(Map<String, List<String>> options) throws IOException {
        FsMetaLoad load = requireTrio(options);
        if (!load.ok()) {
            return 1;
        }
        for (int index = 0; index < load.pair().size(); index++) {
            line(load.pair().entry(index).format(load.pair().name(index)));
        }
        return 0;
    }

    private int diff(List<String> positional) throws IOException {
        if (positional.size() != 2) {
            problem("fsmeta: diff needs two trio directories");
            return 2;
        }
        FsMetaLoad before = FsMetaPair.loadOrFail(Path.of(positional.get(0)));
        FsMetaLoad after = FsMetaPair.loadOrFail(Path.of(positional.get(1)));
        if (!before.ok() || !after.ok()) {
            problem("fsmeta: " + before.describe());
            problem("fsmeta: " + after.describe());
            return 1;
        }
        List<FsMetaDiff.Change> changes = FsMetaDiff.between(before.pair(), after.pair());
        for (FsMetaDiff.Change change : changes) {
            line(change.line());
        }
        Map<FsMetaDiff.Kind, Integer> counts = new LinkedHashMap<>();
        for (FsMetaDiff.Change change : changes) {
            counts.merge(change.kind(), 1, Integer::sum);
        }
        StringBuilder summary = new StringBuilder();
        for (FsMetaDiff.Kind kind : FsMetaDiff.Kind.values()) {
            int count = counts.getOrDefault(kind, 0);
            if (count > 0) {
                summary.append(summary.isEmpty() ? "" : ", ").append(count).append(' ')
                        .append(kind.name().toLowerCase());
            }
        }
        line(summary.isEmpty() ? "no changes" : summary.toString());
        return 0;
    }

    private int repair(Map<String, List<String>> options) throws IOException {
        Path directory = trioDirectory(options);
        byte[] meta = Files.readAllBytes(directory.resolve(FsMetaFormat.META_FILE));
        byte[] txt = Files.readAllBytes(directory.resolve(FsMetaFormat.TXT_FILE));
        FsMetaConfig config;
        try {
            config = FsMetaConfig.parse(
                    new String(Files.readAllBytes(directory.resolve(FsMetaFormat.JSON_FILE)), StandardCharsets.UTF_8));
        } catch (IllegalArgumentException malformed) {
            problem("fsmeta: files.json cannot be read, so the trio cannot be repaired: " + malformed.getMessage());
            return 1;
        }
        FsMetaValidation validation = FsMetaValidator.validate(meta, txt, config);
        if (validation.usable()) {
            line("nothing to repair: " + validation.describe());
            return 0;
        }
        if (validation.verdict() != FsMetaVerdict.NAME_HASH_MISMATCH) {
            problem("fsmeta: only a broken pairing can be repaired by hash, and this trio failed with "
                    + validation.describe());
            return 1;
        }
        Optional<List<FsMetaRepair.Pairing>> pairing = FsMetaRepair.pairByHash(meta, txt);
        if (pairing.isEmpty()) {
            problem("fsmeta: the pairing cannot be recovered: an entry has no distinct matching name");
            return 1;
        }
        List<FsMetaEntry> entries = FsMetaCodec.decodeEntries(meta);
        List<FsMetaFile> files = new ArrayList<>();
        for (FsMetaRepair.Pairing one : pairing.get()) {
            FsMetaEntry entry = entries.get(one.entryIndex());
            files.add(new FsMetaFile(
                    one.name(),
                    entry.mtimeNs(),
                    entry.sizeBytes(),
                    entry.contentHash(),
                    entry.flags() & FsMetaFormat.FLAG_KNOWN_MASK));
        }
        if (options.containsKey("dry-run")) {
            for (FsMetaRepair.Pairing one : pairing.get()) {
                line("entry " + one.entryIndex() + " -> " + one.name());
            }
            line("dry run: " + files.size() + " entry/entries would be republished in name order");
            return 0;
        }
        FsMetaLoad repaired = FsMetaWriter.publish(
                directory,
                files,
                config.hashMode(),
                WRITER,
                config.root().isEmpty() ? directory.getParent().toString() : config.root());
        line("repaired " + files.size() + " entry/entries: " + repaired.describe());
        return repaired.ok() ? 0 : 1;
    }

    // ------------------------------------------------------------------ plumbing

    /** One line of output, always LF: a pipeline must not see a different byte on another platform. */
    private void line(String text) {
        out.print(text + "\n");
        out.flush();
    }

    private void problem(String text) {
        err.print(text + "\n");
        err.flush();
    }

    private void usage() {
        String[] lines = {
                "usage: fsmeta <command> [options]",
                "",
                "  scan   [--root DIR] [--dir DIR] [--ignore NAME]... [--normalize none|lf|text]",
                "         [--writer NAME] [--no-gitignore]",
                "  verify [--dir DIR]",
                "  names  [--dir DIR]",
                "  query  NAME [--dir DIR]",
                "  dump   [--dir DIR]",
                "  diff   DIR_A DIR_B",
                "  repair [--dir DIR] [--dry-run]",
                "",
                "--dir defaults to <root>/.fs-meta, and --root to the working directory.",
                "scan honours .gitignore files in the tree unless --no-gitignore is given.",
                "Exit codes: 0 answered, 1 the subject failed, 2 usage."};
        for (String text : lines) {
            problem(text);
        }
    }

    private FsMetaLoad requireTrio(Map<String, List<String>> options) throws IOException {
        Path directory = trioDirectory(options);
        FsMetaLoad load = FsMetaPair.loadIfPresent(directory);
        if (load == null) {
            problem("fsmeta: no complete fs-meta trio in " + directory + " (run: fsmeta scan)");
            return new FsMetaLoad(directory, FsMetaVerdict.UNSUPPORTED_FORMAT, null, null, "no trio");
        }
        if (!load.ok()) {
            problem("fsmeta: " + load.describe());
        }
        return load;
    }

    private Path trioDirectory(Map<String, List<String>> options) {
        String directory = value(options, "dir");
        if (directory != null) {
            return Path.of(directory);
        }
        return path(options, "root", Path.of("").toAbsolutePath()).resolve(FsMetaFormat.DIRECTORY_NAME);
    }

    private static String parse(
            String[] args, int from, Map<String, List<String>> options, List<String> positional) {
        for (int i = from; i < args.length; i++) {
            String arg = args[i];
            if (!arg.startsWith("--")) {
                positional.add(arg);
                continue;
            }
            String key = arg.substring(2);
            String inline = null;
            int equals = key.indexOf('=');
            if (equals >= 0) {
                inline = key.substring(equals + 1);
                key = key.substring(0, equals);
            }
            if (key.equals("dry-run") || key.equals("help") || key.equals("no-gitignore")) {
                options.computeIfAbsent(key, ignored -> new ArrayList<>()).add("true");
                continue;
            }
            String value = inline;
            if (value == null) {
                if (i + 1 >= args.length) {
                    return "'--" + key + "' needs a value";
                }
                value = args[++i];
            }
            options.computeIfAbsent(key, ignored -> new ArrayList<>()).add(value);
        }
        return null;
    }

    private static String value(Map<String, List<String>> options, String key) {
        List<String> values = options.get(key);
        return values == null || values.isEmpty() ? null : values.get(values.size() - 1);
    }

    private static List<String> values(Map<String, List<String>> options, String key) {
        return options.getOrDefault(key, List.of());
    }

    private static Path path(Map<String, List<String>> options, String key, Path fallback) {
        String value = value(options, key);
        return value == null ? fallback : Path.of(value);
    }
}