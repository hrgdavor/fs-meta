package hr.hrg.wyhash;

import org.junit.Assert;
import org.junit.Test;
import java.nio.charset.StandardCharsets;

public class Wyhash64StreamingTest {

    @Test
    public void testStreamingWithScratchReuse() {
        long seed = 42L;

        // We need totalLen > 16, but the final chunk in the buffer to be < 16.
        // A total length of 20 bytes is perfect: 
        // First 16 bytes pass through or fill up, leaving a 4-byte tail frame (< 16).
        byte[] data1 = "This is a 20-byte st".getBytes(StandardCharsets.UTF_8); // 20 bytes
        byte[] data2 = "Different 20-byte string".substring(0, 20).getBytes(StandardCharsets.UTF_8); // 20 bytes

        // 1. Get the ground truth using the reliable bulk hashing method
        long expectedHash1 = Wyhash64.hash(seed, data1);
        long expectedHash2 = Wyhash64.hash(seed, data2);

        // 2. Test Stream 1
        Wyhash64.Streaming stream1 = new Wyhash64.Streaming(seed);
        stream1.update(data1);
        long streamHash1 = stream1.finalHash();

        // 3. Test Stream 2 (This checks if data1 leaked into data2 via a shared/reused scratch state)
        Wyhash64.Streaming stream2 = new Wyhash64.Streaming(seed);
        stream2.update(data2);
        long streamHash2 = stream2.finalHash();

        // Assertions
        Assert.assertEquals("Stream 1 hash failed to match bulk hash!", expectedHash1, streamHash1);
        Assert.assertEquals("Stream 2 hash failed to match bulk hash! Potential scratch leak.", expectedHash2, streamHash2);
    }

    @Test
    public void testChunkedStreamingMatchesBulk() {
        long seed = 12345L;
        // 50 bytes total ensures we hit the > 48 byte parallel loops AND leave a small remaining tail
        byte[] fullData = " de_sabotage_your_code_with_proper_unit_tests_1234".getBytes(StandardCharsets.UTF_8); 
        
        long expectedHash = Wyhash64.hash(seed, fullData);

        // Feed data in messy, unpredictable chunks to aggressively force the streaming buffer shifts
        Wyhash64.Streaming stream = new Wyhash64.Streaming(seed);
        stream.update(fullData, 0, 10);
        stream.update(fullData, 10, 15);
        stream.update(fullData, 25, 20);
        stream.update(fullData, 45, 5); // Final remaining 5 bytes (forces scratch logic)

        long streamHash = stream.finalHash();

        Assert.assertEquals("Chunked streaming failed to match bulk hash.", expectedHash, streamHash);
    }
}