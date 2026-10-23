// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.nio.charset.StandardCharsets;
import java.util.List;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

/**
 * The entry layout and the name order — {@code FORMAT.md} § 4 and § 5, pinned to the worked example those
 * sections publish rather than to this implementation's own arithmetic.
 */
class FsMetaCodecTest {

    private static String hex(byte[] bytes) {
        return java.util.HexFormat.of().formatHex(bytes);
    }

    private static byte[] hexBytes(String text) {
        return java.util.HexFormat.of().parseHex(text);
    }

    @Test
    void theWorkedExampleLaysOutExactlyAsTheSpecificationSays() {
        // FORMAT.md § 13: a.txt (hello\n, mtime 1700000000123) then src/b.java (class B {}\n, 1700000001456).
        byte[] txt = FsMetaCodec.encodeNames(List.of("a.txt", "src/b.java"));
        Assertions.assertEquals("612e7478740a7372632f622e6a6176610a", hex(txt));

        FsMetaEntry first = FsMetaEntry.forFile("a.txt", 1_700_000_000_123L, 6L,
                FsMetaHash.of(FsMetaHash.utf8("hello\n")), 0L, false);
        FsMetaEntry second = FsMetaEntry.forFile("src/b.java", 1_700_000_001_456L, 11L,
                FsMetaHash.of(FsMetaHash.utf8("class B {}\n")), 6L, false);

        String expected = "7b68e5cf8b01000082c009acd17d916a9059068e3329d1e60600000000000000"
                + "0000000000000000050000000300000000000000000000000000000000000000"
                + "b06de5cf8b0100004b24dab568afd479692d7f9414c2739c0b00000000000000"
                + "06000000000000000a0000000300000000000000000000000000000000000000";
        Assertions.assertEquals(expected, hex(FsMetaCodec.encodeEntries(List.of(first, second))));

        // and the first entry field by field, so a failure says which field moved
        byte[] entry = new byte[FsMetaFormat.ENTRY_SIZE];
        FsMetaCodec.putEntry(java.nio.ByteBuffer.wrap(entry).order(java.nio.ByteOrder.LITTLE_ENDIAN), 0L, first);
        Assertions.assertEquals("7b68e5cf8b010000", hex(java.util.Arrays.copyOfRange(entry, 0, 8)), "mtimeMillis");
        Assertions.assertEquals("82c009acd17d916a", hex(java.util.Arrays.copyOfRange(entry, 8, 16)), "nameHash");
        Assertions.assertEquals("9059068e3329d1e6", hex(java.util.Arrays.copyOfRange(entry, 16, 24)), "contentHash");
        Assertions.assertEquals("0600000000000000", hex(java.util.Arrays.copyOfRange(entry, 24, 32)), "sizeBytes");
        Assertions.assertEquals("0000000000000000", hex(java.util.Arrays.copyOfRange(entry, 32, 40)), "nameOffset");
        Assertions.assertEquals("05000000", hex(java.util.Arrays.copyOfRange(entry, 40, 44)), "nameLength");
        Assertions.assertEquals("03000000", hex(java.util.Arrays.copyOfRange(entry, 44, 48)), "flags");
        Assertions.assertEquals("0000000000000000", hex(java.util.Arrays.copyOfRange(entry, 48, 56)), "fileId");
        Assertions.assertEquals("0000000000000000", hex(java.util.Arrays.copyOfRange(entry, 56, 64)), "reserved");
    }

    @Test
    void theTwoNamesHashToTheLibraryValues() {
        // The same two values FORMAT.md § 13 prints, produced by hr.hrg.wyhash:wyhash:1.0.0.
        Assertions.assertEquals("6a917dd1ac09c082", FsMetaHash.hex(FsMetaHash.ofName("a.txt")));
        Assertions.assertEquals("79d4af68b5da244b", FsMetaHash.hex(FsMetaHash.ofName("src/b.java")));
        Assertions.assertEquals("e6d129338e065990", FsMetaHash.hex(FsMetaHash.of(FsMetaHash.utf8("hello\n"))));
        Assertions.assertEquals("9c73c214947f2d69", FsMetaHash.hex(FsMetaHash.of(FsMetaHash.utf8("class B {}\n"))));
    }

    @Test
    void decodeIsTheInverseOfEncodeForEveryField() {
        FsMetaEntry awkward = new FsMetaEntry(
                -1L, 0L, Long.MIN_VALUE, Long.MAX_VALUE, 0x0123_4567_89AB_CDEFL, -2, 0x0102_0304, 7L, 9L);
        FsMetaEntry plain = FsMetaEntry.forFile("README.md", 0L, 0L, 0L, 0L, false);
        List<FsMetaEntry> decoded = FsMetaCodec.decodeEntries(
                FsMetaCodec.encodeEntries(List.of(awkward, plain)));
        Assertions.assertEquals(List.of(awkward, plain), decoded,
                "the layout is unsigned on the wire, so a negative field must round-trip bit for bit");
    }

    @Test
    void entryCountIsAShiftAndAMisalignedFileIsRefused() {
        Assertions.assertEquals(0L, FsMetaFormat.entryCount(0));
        Assertions.assertEquals(1L, FsMetaFormat.entryCount(64));
        Assertions.assertEquals(17L, FsMetaFormat.entryCount(17 * 64));
        Assertions.assertEquals(1088L, FsMetaFormat.entryOffset(17));
        Assertions.assertThrows(IllegalArgumentException.class, () -> FsMetaFormat.entryCount(65));
        Assertions.assertThrows(IllegalArgumentException.class, () -> FsMetaFormat.entryCount(-1));
    }

    @Test
    void namesAreOrderedByTheirBytesNotByTheirUtf16Units() {
        String fullWidth = "\uFF21";     // U+FF21, UTF-8 EF BC A1
        String emoji = "\uD83D\uDE00";   // U+1F600, UTF-8 F0 9F 98 80

        Assertions.assertTrue(fullWidth.compareTo(emoji) > 0,
                "the premise: UTF-16 order puts the emoji first, because a surrogate is 0xD83D");
        Assertions.assertTrue(FsMetaFormat.NAME_ORDER.compare(fullWidth, emoji) < 0,
                "the format orders by UTF-8 bytes, where EF comes before F0");
    }

    @Test
    void namesAreOrderedAsMemcmpWould() {
        List<String> names = new java.util.ArrayList<>(List.of("b.java", "a.txt", "src/b.java", "A.txt"));
        names.sort(FsMetaFormat.NAME_ORDER);
        Assertions.assertEquals(List.of("A.txt", "a.txt", "b.java", "src/b.java"), names,
                "uppercase sorts before lowercase, because 0x41 is below 0x61");
    }

    @Test
    void theFlagsSayWhatTheEntryMeans() {
        FsMetaEntry hashed = FsMetaEntry.forFile("a.txt", 1L, 2L, 3L, 0L, true);
        Assertions.assertTrue(hashed.contentKnown());
        Assertions.assertTrue(hashed.regularFile());
        Assertions.assertTrue(hashed.hashLf());
        Assertions.assertTrue(hashed.usableFingerprint());

        FsMetaEntry listingOnly = FsMetaEntry.listingOnly("a.txt", 0L);
        Assertions.assertFalse(listingOnly.contentKnown());
        Assertions.assertTrue(listingOnly.trusted());
        Assertions.assertFalse(listingOnly.usableFingerprint(),
                "listing-only means there is nothing to compare, so a tool reads the file");

        FsMetaEntry future = new FsMetaEntry(1L, 2L, 3L, 4L, 0L, 5, 0x10, 0L, 0L);
        Assertions.assertFalse(future.trusted(), "an unknown flag bit makes the entry untrusted");
        Assertions.assertEquals(0x10, future.unknownFlagBits());
    }

    @Test
    void namesRoundTripThroughUtf8() {
        String name = "src/héllo — ünïcode/😀.java";
        byte[] txt = FsMetaCodec.encodeNames(List.of(name));
        FsMetaEntry entry = FsMetaEntry.forFile(name, 0L, 0L, 0L, 0L, false);
        Assertions.assertEquals(name, new String(txt, 0, entry.nameLength(), StandardCharsets.UTF_8));
        Assertions.assertEquals(name.length() > 0, entry.nameLength() > 0);
    }

    @Test
    void anEncodedPairIsTheBytesTheVectorsExpect() {
        // A guard for the two helpers the conformance test compares against the vector file.
        Assertions.assertArrayEquals(hexBytes("612e7478740a"),
                FsMetaCodec.encodeNames(List.of("a.txt")));
    }
}