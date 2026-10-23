// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Davor Hrg
package hr.hrg.wyhash;

import org.junit.Test;
import static org.junit.Assert.assertEquals;

public class WyhashTestVectors {

    @Test
    public void testVectors() {
        // Zig test vectors:
        // .{ .seed = 0, .expected = 0x0409638ee2bde459, .input = "" },
        // .{ .seed = 1, .expected = 0xa8412d091b5fe0a9, .input = "a" },
        // .{ .seed = 2, .expected = 0x32dd92e4b2915153, .input = "abc" },

        assertEquals("0409638ee2bde459", String.format("%016x", Wyhash64.hash(0, "".getBytes())));
        assertEquals("a8412d091b5fe0a9", String.format("%016x", Wyhash64.hash(1, "a".getBytes())));
        assertEquals("32dd92e4b2915153", String.format("%016x", Wyhash64.hash(2, "abc".getBytes())));
    }
}
