// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * The walk's ignore behaviour against the shared vectors: {@code gitignoreCases} in
 * {@code conformance/fsmeta-vectors.json}.
 *
 * <p>Each case is a tree to materialise plus the list of files a walk must produce, so this is the test that
 * keeps two implementations of the walk <em>the same walk</em> rather than two opinions about git. {@code
 * includedWithoutGitignore}, where a case carries it, pins the other mode too — a caller that lists
 * everything regardless of {@code .gitignore}.</p>
 */
class GitIgnoreVectorsTest {

    @TempDir
    Path workspace;

    @Test
    void everyIgnoreCaseWalksToTheListedFiles() throws IOException {
        Map<String, Object> vectors = vectors();
        int checked = 0;
        for (Object entry : asList(vectors.get("gitignoreCases"))) {
            Map<String, Object> vector = asMap(entry);
            String label = text(vector.get("label"));
            Path root = workspace.resolve(label);

            materialize(root, vector);

            List<String> walked = names(root, FsMetaScanOptions.defaults());
            Assertions.assertEquals(asTextList(vector.get("included")), walked,
                    "the walk for ignore case '" + label + "': " + text(vector.get("explain")));

            if (vector.containsKey("includedWithoutGitignore")) {
                List<String> unignored = names(root, FsMetaScanOptions.defaults().withoutGitignore());
                Assertions.assertEquals(asTextList(vector.get("includedWithoutGitignore")), unignored,
                        "the same tree with .gitignore reading switched off ('" + label + "')");
            }
            checked++;
        }
        Assertions.assertTrue(checked >= 10, "the vector file should cover the walk's rules; got " + checked);
    }

    @Test
    void everyIgnoreCaseAgreesWithATreeThatListsNothingTwice() throws IOException {
        // A second property, cheap to check and worth pinning: a scan of a tree with no .gitignore at all,
        // with reading switched off, lists exactly the regular files that exist (minus .git and .fs-meta).
        Map<String, Object> vectors = vectors();
        for (Object entry : asList(vectors.get("gitignoreCases"))) {
            Map<String, Object> vector = asMap(entry);
            Path root = workspace.resolve("files-" + text(vector.get("label")));
            materialize(root, vector);
            List<String> walked = names(root, FsMetaScanOptions.defaults().withoutGitignore());
            List<String> expected = new ArrayList<>(asTextList(vector.get("files")));
            for (String gitignore : asMap(vector.get("gitignores")).keySet()) {
                expected.add(gitignore);
            }
            // `.git` and `.fs-meta` are never listed, whatever the mode.
            expected.removeIf(name -> name.startsWith(".git/") || name.startsWith(FsMetaFormat.DIRECTORY_NAME + "/"));
            expected.sort(FsMetaFormat.NAME_ORDER);
            Assertions.assertEquals(expected, walked,
                    "with .gitignore off, everything but .git and .fs-meta is listed ('" + text(vector.get("label")) + "')");
        }
    }

    // ------------------------------------------------------------------ helpers

    private static List<String> names(Path root, FsMetaScanOptions options) throws IOException {
        List<String> names = new ArrayList<>();
        for (FsMetaFile file : FsMetaScanner.scan(root, options)) {
            names.add(file.name());
        }
        return names;
    }

    private static void materialize(Path root, Map<String, Object> vector) throws IOException {
        Files.createDirectories(root);
        for (Object file : asList(vector.get("files"))) {
            Path path = root.resolve(text(file));
            Files.createDirectories(path.getParent());
            Files.writeString(path, "content of " + text(file) + "\n", StandardCharsets.UTF_8);
        }
        for (Map.Entry<String, Object> ignore : asMap(vector.get("gitignores")).entrySet()) {
            Path path = root.resolve(ignore.getKey());
            Files.createDirectories(path.getParent());
            Files.writeString(path, text(ignore.getValue()), StandardCharsets.UTF_8);
        }
    }

    private static Map<String, Object> vectors() throws IOException {
        List<Path> candidates = List.of(
                Path.of("conformance", "fsmeta-vectors.json"),
                Path.of("fs-meta", "conformance", "fsmeta-vectors.json"));
        for (Path candidate : candidates) {
            if (Files.isRegularFile(candidate)) {
                return asMap(Json.parse(Files.readString(candidate, StandardCharsets.UTF_8)));
            }
        }
        throw new IllegalStateException("fsmeta-vectors.json not found from " + Path.of("").toAbsolutePath());
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> asMap(Object value) {
        return value instanceof Map ? (Map<String, Object>) value : new LinkedHashMap<>();
    }

    @SuppressWarnings("unchecked")
    private static List<Object> asList(Object value) {
        return value instanceof List ? (List<Object>) value : List.of();
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