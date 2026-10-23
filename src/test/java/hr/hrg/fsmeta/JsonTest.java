// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

/**
 * The minimal JSON reader and writer the sidekick document and the vectors are read with.
 *
 * <p>It is a small parser, so its contract is pinned rather than assumed: what it accepts, what it refuses,
 * and the property the format depends on — an unknown key survives a read/write round trip in its original
 * position.</p>
 */
class JsonTest {

    @Test
    void readsTheFiveKindsOfValue() {
        Object parsed = Json.parse("""
                {"s":"text","i":42,"d":1.5,"b":true,"n":null,"a":[1,2,3],"o":{"k":"v"}}""");
        Map<?, ?> object = (Map<?, ?>) parsed;
        Assertions.assertEquals("text", object.get("s"));
        Assertions.assertEquals(42L, object.get("i"));
        Assertions.assertEquals(1.5, object.get("d"));
        Assertions.assertEquals(Boolean.TRUE, object.get("b"));
        Assertions.assertNull(object.get("n"));
        Assertions.assertEquals(List.of(1L, 2L, 3L), object.get("a"));
        Assertions.assertEquals(Map.of("k", "v"), object.get("o"));
    }

    @Test
    void readsEveryEscapeTheFormatCanWrite() {
        Object parsed = Json.parse("""
                {"t":"a\\tb\\nc\\rd\\"e\\\\f\\/g\\u0041"}""");
        Assertions.assertEquals("a\tb\nc\rd\"e\\f/gA", ((Map<?, ?>) parsed).get("t"));
    }

    @Test
    void writesWhatItReadsBack() {
        String document = """
                {"format":"fs-meta","version":1,"nested":{"bytes":128},"list":["a","b"]}""";
        String rewritten = Json.write(Json.parse(document));
        Assertions.assertEquals(document, rewritten, "a round trip must be lossless and key-ordered");
    }

    @Test
    void keepsTheKeyOrderSoAnUnknownKeySurvivesARewrite() {
        FsMetaConfig config = FsMetaConfig.parse("""
                {"format":"fs-meta","version":1,"entrySize":64,"count":0,
                 "meta":{"bytes":0,"wyhash":"0000000000000000"},
                 "txt":{"bytes":0,"wyhash":"0000000000000000"},
                 "hash":{"content":"wyhash64","name":"wyhash64","seed":0,"normalize":"none"},
                 "futureKey":{"kept":true}}""");
        Assertions.assertTrue(config.extra().containsKey("futureKey"),
                "a key this version does not know is kept, not dropped");
        Assertions.assertTrue(config.toJson().contains("\"futureKey\":{\"kept\":true}"),
                "and it is written back: " + config.toJson());
    }

    @Test
    void refusesWhatTheGrammarDoesNotAllow() {
        List<String> refused = List.of(
                "{'single':'quotes'}",
                "{\"a\":1,}",
                "{\"a\":1} extra",
                "{a:1}",
                "[1,2",
                "\"unterminated",
                "{\"a\":01}",
                "{\"a\":+1}",
                "{\"a\":NaN}",
                "",
                "{/*comment*/\"a\":1}");
        for (String text : refused) {
            Assertions.assertThrows(IllegalArgumentException.class, () -> Json.parse(text),
                    "this must not parse: " + text);
        }
    }

    @Test
    void refusesNestingPastItsDepthLimit() {
        String deep = "[".repeat(Json.MAX_DEPTH + 2) + "]".repeat(Json.MAX_DEPTH + 2);
        IllegalArgumentException failure = Assertions.assertThrows(IllegalArgumentException.class,
                () -> Json.parse(deep));
        Assertions.assertTrue(failure.getMessage().contains("deeper than"), failure.getMessage());
    }

    @Test
    void reportsWhereAProblemIsInTheDocument() {
        IllegalArgumentException failure = Assertions.assertThrows(IllegalArgumentException.class,
                () -> Json.parse("{\n  \"a\": 1,\n  \"b\": }\n"));
        Assertions.assertTrue(failure.getMessage().contains("line 3"), failure.getMessage());
    }
}