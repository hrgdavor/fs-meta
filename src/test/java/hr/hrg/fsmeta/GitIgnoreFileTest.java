// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.util.Optional;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import hr.hrg.gitignore.GitIgnoreFile;
import hr.hrg.gitignore.GitIgnoreRules;

/**
 * The {@code .gitignore} semantics themselves — the rules a walk depends on, each stated as one case so a
 * failure names the rule rather than a tree.
 *
 * <p>The shared vectors ({@code GitIgnoreVectorsTest} and {@code conformance/gitignoreCases}) pin the whole
 * walk across ports; these tests pin the individual rules that the vectors cover in combination, which is
 * where a rule is most likely to be "fixed" wrongly.</p>
 */
class GitIgnoreFileTest {

    private static GitIgnoreFile atRoot(String text) {
        return GitIgnoreFile.parse("", text);
    }

    private static boolean ignored(String pattern, String path) {
        return atRoot(pattern).decide(path, false).orElse(false);
    }

    @Test
    void aNameOnlyPatternMatchesAtAnyDepth() {
        Assertions.assertTrue(ignored("*.log", "debug.log"));
        Assertions.assertTrue(ignored("*.log", "src/deep/debug.log"));
        Assertions.assertTrue(ignored("build", "sub/build"));
        Assertions.assertFalse(ignored("*.log", "debug.txt"));
    }

    @Test
    void aPatternWithASeparatorIsAnchoredToTheIgnoreFilesDirectory() {
        Assertions.assertTrue(ignored("/root-only.txt", "root-only.txt"));
        Assertions.assertFalse(ignored("/root-only.txt", "sub/root-only.txt"));
        Assertions.assertTrue(ignored("doc/*.txt", "doc/a.txt"));
        Assertions.assertFalse(ignored("doc/*.txt", "other/doc/a.txt"));
    }

    @Test
    void theLastMatchingPatternWins() {
        Assertions.assertFalse(ignored("*.log\n!keep.log\n", "keep.log"));
        Assertions.assertTrue(ignored("*.log\n!keep.log\n", "other.log"));
        Assertions.assertTrue(ignored("!keep.log\n*.log\n", "keep.log"),
                "a negation is not special: the last pattern that matches decides");
    }

    @Test
    void aTrailingSlashMeansDirectoriesOnly() {
        GitIgnoreFile rules = atRoot("out/\n");
        Assertions.assertTrue(rules.decide("out", true).orElseThrow(), "the directory is excluded");
        Assertions.assertFalse(rules.decide("out", false).orElse(false), "a file called out is not");
        // `GitIgnoreFile` is one file's rules, so it cannot answer about an ancestor; the walk's
        // answer comes from the stack, which knows which directory is excluded — and that is what
        // git reports for a file inside an excluded directory.
        GitIgnoreRules stack = new GitIgnoreRules();
        stack.push(rules);
        Assertions.assertTrue(stack.isIgnored("out/x.txt", false),
                "and git reports a file inside an excluded directory as ignored too");
    }

    @Test
    void doubleStarFormsFollowGitsRules() {
        Assertions.assertTrue(ignored("docs/**/*.md", "docs/a.md"));
        Assertions.assertTrue(ignored("docs/**/*.md", "docs/x/y/b.md"));
        Assertions.assertFalse(ignored("docs/**/*.md", "docs/x/y/b.txt"));
        Assertions.assertTrue(ignored("logs/**", "logs/x/y.txt"));
        Assertions.assertFalse(ignored("logs/**", "logs.txt"), "the directory itself is not 'inside'");
        Assertions.assertTrue(ignored("**/generated", "a/b/generated"));
        Assertions.assertFalse(ignored("**/generated", "a/b/generated.txt"));
        Assertions.assertFalse(ignored("a**b", "a/b"),
                "consecutive asterisks that are not a segment of their own are just asterisks");
        Assertions.assertTrue(ignored("a**b", "axxb"));
    }

    @Test
    void theScopeOfAFileIsItsOwnDirectory() {
        GitIgnoreFile inSub = GitIgnoreFile.parse("sub", "*.log\n");
        Assertions.assertTrue(inSub.decide("sub/x.log", false).orElseThrow());
        Assertions.assertTrue(inSub.decide("sub/deep/x.log", false).orElseThrow());
        Assertions.assertTrue(inSub.decide("x.log", false).isEmpty(),
                "a file below `sub` is governed by sub/.gitignore; one outside it is not");
        Assertions.assertTrue(inSub.decide("sub", true).isEmpty(),
                "and a directory's own .gitignore never excludes the directory itself");
    }

    @Test
    void aDecisionIsEmptyWhenNoPatternMatches() {
        Optional<Boolean> decision = atRoot("*.log\n").decide("a.txt", false);
        Assertions.assertTrue(decision.isEmpty(),
                "empty is not 'included': a shallower .gitignore may still have an opinion");
    }

    @Test
    void commentsBlankLinesAndTrailingSpacesAreHandled() {
        GitIgnoreFile rules = atRoot("# a comment\n\n   \nkeep-me \nafter\n");
        Assertions.assertEquals(2, rules.ruleCount(), "comments and blank lines are not patterns");
        Assertions.assertTrue(rules.decide("keep-me", false).orElse(false),
                "trailing spaces are ignored, so the pattern is `keep-me`");
        Assertions.assertTrue(rules.decide("after", false).orElse(false));
        Assertions.assertTrue(rules.decide("# a comment", false).isEmpty());
    }

    @Test
    void anEscapedMarkerIsALiteralCharacter() {
        Assertions.assertTrue(ignored("\\#literal", "#literal"));
        Assertions.assertTrue(ignored("\\!literal", "!literal"));
        Assertions.assertTrue(ignored("a\\*b", "a*b"));
    }

    @Test
    void characterClassesFollowFnmatch() {
        Assertions.assertTrue(ignored("file[0-9].txt", "file7.txt"));
        Assertions.assertFalse(ignored("file[0-9].txt", "filex.txt"));
        Assertions.assertTrue(ignored("[!a].txt", "b.txt"));
        Assertions.assertFalse(ignored("[!a].txt", "a.txt"));
        Assertions.assertTrue(ignored("[abc].dat", "c.dat"));
        Assertions.assertFalse(ignored("no[class", "no[class"),
                "an unterminated class matches nothing: git's wildmatch aborts the pattern, which is what the "
                        + "shared gitignore-vectors.json case 'an unterminated class matches nothing' pins");
        Assertions.assertFalse(ignored("no[class", "noXclass"));
        Assertions.assertTrue(ignored("q?estion", "question"));
        Assertions.assertFalse(ignored("q?estion", "qestion"), "? needs exactly one character");
    }

    @Test
    void matchingIsCaseSensitiveOnEveryPlatform() {
        Assertions.assertFalse(ignored("Foo.txt", "foo.txt"),
                "the ports must agree with each other before they agree with a file system");
        Assertions.assertTrue(ignored("Foo.txt", "Foo.txt"));
    }

    @Test
    void aPatternNeverCrossesASeparatorWithASingleStar() {
        Assertions.assertTrue(ignored("*.tmp", "sub/deep/a.tmp"));
        Assertions.assertFalse(ignored("sub/*.tmp", "sub/deep/a.tmp"));
        Assertions.assertTrue(ignored("sub/*.tmp", "sub/a.tmp"));
    }

    @Test
    void deeperRulesDecideBeforeShallowerOnes() {
        GitIgnoreRules rules = new GitIgnoreRules();
        rules.push(atRoot("*.tmp\n"));
        rules.push(GitIgnoreFile.parse("src", "!keep.tmp\n"));
        Assertions.assertEquals(2, rules.depth());
        Assertions.assertTrue(rules.isIgnored("src/a.tmp", false));
        Assertions.assertFalse(rules.isIgnored("src/keep.tmp", false), "the deeper file re-includes it");
        Assertions.assertTrue(rules.isIgnored("other.tmp", false), "the outer file still decides elsewhere");
        rules.pop();
        Assertions.assertTrue(rules.isIgnored("src/keep.tmp", false), "with the inner file gone, the outer wins");
        Assertions.assertEquals(1, rules.depth());
    }
}