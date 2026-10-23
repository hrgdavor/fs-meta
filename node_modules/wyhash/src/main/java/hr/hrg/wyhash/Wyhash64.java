// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Davor Hrg
package hr.hrg.wyhash;

import java.lang.invoke.MethodHandles;
import java.lang.invoke.VarHandle;
import java.nio.ByteOrder;

/**
 * Standalone implementation of Wyhash matching Zig 0.15 std.hash.Wyhash.
 */
public final class Wyhash64 {

    private static final long[] DEFAULT_SECRET = {
            0xa0761d6478bd642fL, 0xe7037ed1a0b428dbL, 0x8ebc6af09c88c6e3L, 0x589965cc75374cc3L
    };

    private static final VarHandle LONG_HANDLE = MethodHandles.byteArrayViewVarHandle(long[].class,
            ByteOrder.LITTLE_ENDIAN);
    private static final VarHandle INT_HANDLE = MethodHandles.byteArrayViewVarHandle(int[].class,
            ByteOrder.LITTLE_ENDIAN);

    private static final VarHandle BB_LONG_HANDLE = MethodHandles.byteBufferViewVarHandle(long[].class,
            ByteOrder.LITTLE_ENDIAN);
    private static final VarHandle BB_INT_HANDLE = MethodHandles.byteBufferViewVarHandle(int[].class,
            ByteOrder.LITTLE_ENDIAN);

    private Wyhash64() {
    }

    public static long hash(long seed, byte[] data) {
        return hash(seed, data, 0, data.length);
    }

    public static long hash(long seed, byte[] data, int off, int len) {
        long s = initSeed(seed);
        long secret1 = DEFAULT_SECRET[1];
        long secret2 = DEFAULT_SECRET[2];
        long secret3 = DEFAULT_SECRET[3];

        long a, b;

        if (len <= 16) {
            if (len >= 4) {
                a = ((long) getInt(data, off) << 32) | (getInt(data, off + ((len >> 3) << 2)) & 0xFFFFFFFFL);
                b = ((long) getInt(data, off + len - 4) << 32)
                        | (getInt(data, off + len - 4 - ((len >> 3) << 2)) & 0xFFFFFFFFL);
            } else if (len > 0) {
                a = wyr3(data, off, len);
                b = 0;
            } else {
                a = 0;
                b = 0;
            }
        } else {
            int i = len;
            int p = off;
            long see0 = s;
            long see1 = s;
            long see2 = s;

            while (i > 48) {
                see0 = mix(getLong(data, p) ^ secret1, getLong(data, p + 8) ^ see0);
                see1 = mix(getLong(data, p + 16) ^ secret2, getLong(data, p + 24) ^ see1);
                see2 = mix(getLong(data, p + 32) ^ secret3, getLong(data, p + 40) ^ see2);
                p += 48;
                i -= 48;
            }
            see0 ^= see1 ^ see2;
            while (i > 16) {
                see0 = mix(getLong(data, p) ^ secret1, getLong(data, p + 8) ^ see0);
                i -= 16;
                p += 16;
            }
            a = getLong(data, off + len - 16);
            b = getLong(data, off + len - 8);
            s = see0;
        }

        return finish(a, b, s, len);
    }

    public static long hash(long seed, java.nio.ByteBuffer data) {
        return hash(seed, data, data.position(), data.remaining());
    }

    public static long hash(long seed, java.nio.ByteBuffer data, int off, int len) {
        long s = initSeed(seed);
        long secret1 = DEFAULT_SECRET[1];
        long secret2 = DEFAULT_SECRET[2];
        long secret3 = DEFAULT_SECRET[3];

        long a, b;

        if (len <= 16) {
            if (len >= 4) {
                a = ((long) getInt(data, off) << 32) | (getInt(data, off + ((len >> 3) << 2)) & 0xFFFFFFFFL);
                b = ((long) getInt(data, off + len - 4) << 32)
                        | (getInt(data, off + len - 4 - ((len >> 3) << 2)) & 0xFFFFFFFFL);
            } else if (len > 0) {
                a = wyr3(data, off, len);
                b = 0;
            } else {
                a = 0;
                b = 0;
            }
        } else {
            int i = len;
            int p = off;
            long see0 = s;
            long see1 = s;
            long see2 = s;

            while (i > 48) {
                see0 = mix(getLong(data, p) ^ secret1, getLong(data, p + 8) ^ see0);
                see1 = mix(getLong(data, p + 16) ^ secret2, getLong(data, p + 24) ^ see1);
                see2 = mix(getLong(data, p + 32) ^ secret3, getLong(data, p + 40) ^ see2);
                p += 48;
                i -= 48;
            }
            see0 ^= see1 ^ see2;
            while (i > 16) {
                see0 = mix(getLong(data, p) ^ secret1, getLong(data, p + 8) ^ see0);
                i -= 16;
                p += 16;
            }
            a = getLong(data, off + len - 16);
            b = getLong(data, off + len - 8);
            s = see0;
        }

        return finish(a, b, s, len);
    }

    private static long initSeed(long seed) {
        return seed ^ mix(seed ^ DEFAULT_SECRET[0], DEFAULT_SECRET[1]);
    }

    private static long mix(long a, long b) {
        long low = a * b;
        long high = Math.unsignedMultiplyHigh(a, b);
        return low ^ high;
    }

    private static long finish(long a, long b, long seed, long len) {
        long _a = a ^ DEFAULT_SECRET[1];
        long _b = b ^ seed;
        long low = _a * _b;
        long high = Math.multiplyHigh(_a, _b) + ((_a >> 63) & _b) + ((_b >> 63) & _a);
        return mix(low ^ DEFAULT_SECRET[0] ^ len, high ^ DEFAULT_SECRET[1]);
    }

    private static long wyr3(byte[] data, int off, int k) {
        return ((data[off] & 0xFFL) << 16) | ((data[off + (k >> 1)] & 0xFFL) << 8) | (data[off + k - 1] & 0xFFL);
    }

    private static long wyr3(java.nio.ByteBuffer data, int off, int k) {
        return ((data.get(off) & 0xFFL) << 16) | ((data.get(off + (k >> 1)) & 0xFFL) << 8)
                | (data.get(off + k - 1) & 0xFFL);
    }

    public static final class Streaming {
        private long a, b;
        private final long[] state = new long[3];
        private long totalLen;
        private final byte[] buf = new byte[48];
        private final byte[] scratch = new byte[16];
        private int bufLen;

        public Streaming(long seed) {
            long s = initSeed(seed);
            this.state[0] = s;
            this.state[1] = s;
            this.state[2] = s;
            this.totalLen = 0;
            this.bufLen = 0;
        }

        public void update(byte[] input) {
            update(input, 0, input.length);
        }

        public void update(byte[] input, int off, int len) {
            this.totalLen += len;

            if (len <= 48 - bufLen) {
                System.arraycopy(input, off, buf, bufLen, len);
                bufLen += len;
                return;
            }

            int i = 0;
            if (bufLen > 0) {
                i = 48 - bufLen;
                System.arraycopy(input, off, buf, bufLen, i);
                round(buf, 0);
                bufLen = 0;
            }

            while (i + 48 < len) {
                round(input, off + i);
                i += 48;
            }

            int remaining = len - i;
            if (remaining < 16 && i >= 48) {
                int rem = 16 - remaining;
                System.arraycopy(input, off + i - rem, buf, 48 - rem, rem);
            }
            System.arraycopy(input, off + i, buf, 0, remaining);
            bufLen = remaining;
        }

        private void round(byte[] input, int p) {
            state[0] = mix(getLong(input, p) ^ DEFAULT_SECRET[1], getLong(input, p + 8) ^ state[0]);
            state[1] = mix(getLong(input, p + 16) ^ DEFAULT_SECRET[2], getLong(input, p + 24) ^ state[1]);
            state[2] = mix(getLong(input, p + 32) ^ DEFAULT_SECRET[3], getLong(input, p + 40) ^ state[2]);
        }

        public long finalHash() {
            long _a = a;
            long _b = b;
            long[] _state = { state[0], state[1], state[2] };
            byte[] input = buf;
            int inputLen = bufLen;

            if (totalLen <= 16) {
                if (inputLen >= 4) {
                    int end = inputLen - 4;
                    int quarter = (inputLen >> 3) << 2;
                    _a = ((long) getInt(input, 0) << 32) | (getInt(input, quarter) & 0xFFFFFFFFL);
                    _b = ((long) getInt(input, end) << 32) | (getInt(input, end - quarter) & 0xFFFFFFFFL);
                } else if (inputLen > 0) {
                    _a = ((input[0] & 0xFFL) << 16) | ((input[inputLen >> 1] & 0xFFL) << 8)
                            | (input[inputLen - 1] & 0xFFL);
                    _b = 0;
                } else {
                    _a = 0;
                    _b = 0;
                }
            } else {
                if (inputLen < 16) {
                    int rem = 16 - inputLen;
                    System.arraycopy(buf, 48 - rem, scratch, 0, rem);
                    System.arraycopy(buf, 0, scratch, rem, inputLen);
                    input = scratch;
                    inputLen = 16;
                }

                if (totalLen >= 48) {
                    _state[0] ^= _state[1] ^ _state[2];
                }

                int i = 0;
                while (i + 16 < inputLen) {
                    _state[0] = mix(getLong(input, i) ^ DEFAULT_SECRET[1], getLong(input, i + 8) ^ _state[0]);
                    i += 16;
                }

                _a = getLong(input, inputLen - 16);
                _b = getLong(input, inputLen - 8);
            }

            return finish(_a, _b, _state[0], totalLen);
        }
    }

    private static int getInt(byte[] b, int off) {
        return (int) INT_HANDLE.get(b, off);
    }

    private static long getLong(byte[] b, int off) {
        return (long) LONG_HANDLE.get(b, off);
    }

    private static int getInt(java.nio.ByteBuffer b, int off) {
        return (int) BB_INT_HANDLE.get(b, off);
    }

    private static long getLong(java.nio.ByteBuffer b, int off) {
        return (long) BB_LONG_HANDLE.get(b, off);
    }
}
