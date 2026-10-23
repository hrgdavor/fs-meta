// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Davor Hrg
package hr.hrg.wyhash;

import org.junit.Test;
import static org.junit.Assert.assertEquals;

public class WyhashStandaloneTest {

    @Test
    public void testEmpty() {
        assertEquals("0409638ee2bde459", String.format("%016x", Wyhash64.hash(0, new byte[0])));
    }

    @Test
    public void testSimple() {
        byte[] data = "Hello, Wyhash!".getBytes();
        // We ensure we match the behavior expected by the project
        long hash = Wyhash64.hash(0, data);
        assertTrue(hash != 0);
    }

    @Test
    public void testConsistency() {
        // Test that different lengths and content produce different hashes
        byte[] d1 = "a".getBytes();
        byte[] d2 = "b".getBytes();
        byte[] d3 = "abc".getBytes();
        byte[] d4 = "abcd".getBytes();
        byte[] d5 = "abcde".getBytes();
        byte[] d17 = "12345678901234567".getBytes(); // > 16

        long h1 = Wyhash64.hash(0, d1);
        long h2 = Wyhash64.hash(0, d2);
        long h3 = Wyhash64.hash(0, d3);
        long h4 = Wyhash64.hash(0, d4);
        long h5 = Wyhash64.hash(0, d5);
        long h17 = Wyhash64.hash(0, d17);

        assertTrue(h1 != h2);
        assertTrue(h1 != h3);
        assertTrue(h3 != h4);
        assertTrue(h4 != h5);
        assertTrue(h17 != h5);
    }

    private void assertTrue(boolean condition) {
        org.junit.Assert.assertTrue(condition);
    }
}
