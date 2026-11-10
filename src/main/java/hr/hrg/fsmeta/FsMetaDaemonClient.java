// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.List;

/**
 * The Java client for the fs-meta daemon's Unix-socket protocol ({@code FORMAT.socket.md}).
 *
 * <p>This is a transport, not a watcher or a policy: it connects, greets, subscribes at a stage, and turns the
 * frames into {@link Event}s. The staged-build additions are first-class: a client can subscribe with
 * {@code SUBSCRIBE_V3}, receive {@code STAGE_READY} and the producer stage's
 * {@code STAGE_BATCH_START}/{@code STAGE_CHANGE_ENTRY}/{@code STAGE_BATCH_END} stream, and acknowledge work with
 * {@link #sendBuildStarted(long)} and {@link #sendBuildDone(long, int)}.</p>
 *
 * <p>Unknown frames raise rather than being skipped: a skipped change or stage entry is a silently wrong
 * consumer. {@code PING} is answered, and {@code ERROR} becomes a {@link ProtocolException} carrying the wire
 * code and word.</p>
 */
public final class FsMetaDaemonClient implements AutoCloseable {

    /** The fixed protocol major/minor this client speaks ({@code FORMAT.socket.md} § Versioning). */
    public static final int PROTOCOL = 0x0105;
    /** Subscribe after the daemon's current generation. */
    public static final long LATEST = -1;
    /** The largest stage number a {@code SUBSCRIBE_V2}/{@code SUBSCRIBE_V3} may name. */
    public static final int MAX_STAGE = 64;

    public static final int ERROR_PROTOCOL = 1;
    public static final int ERROR_BATCH_TOO_OLD = 2;
    public static final int ERROR_BATCH_GAP = 3;

    public static final int BUILD_OK = 0;
    public static final int BUILD_FAILED = 1;
    public static final int BUILD_CANCELLED = 2;

    public static final int STATE_OFF = 0;
    public static final int STATE_ASLEEP = 1;
    public static final int STATE_WAKING = 2;
    public static final int STATE_WATCHING = 3;

    private static final int KIND_HELLO = 0x01;
    private static final int KIND_START_BATCH = 0x02;
    private static final int KIND_CHANGE_ENTRY = 0x03;
    private static final int KIND_END_BATCH = 0x04;
    private static final int KIND_ERROR = 0x05;
    private static final int KIND_PING = 0x07;
    private static final int KIND_PONG = 0x08;
    private static final int KIND_STATE = 0x09;
    private static final int KIND_GIT_EVENT = 0x0a;
    private static final int KIND_STAGE_READY = 0x0e;
    private static final int KIND_STAGE_BATCH_START = 0x0f;
    private static final int KIND_STAGE_CHANGE_ENTRY = 0x10;
    private static final int KIND_STAGE_BATCH_END = 0x11;
    private static final int KIND_SUBSCRIBE_V3 = 0x12;

    private static final int ENTRY_SIZE = 64;
    private static final int MAX_FRAME = 1 << 20;
    private static final int HELLO_SIZE = 24;

    private final SocketChannel channel;
    private final int stage;
    private final long serverGeneration;
    private int currentStage;

    private FsMetaDaemonClient(SocketChannel channel, int stage, long serverGeneration) {
        this.channel = channel;
        this.stage = stage;
        this.currentStage = stage;
        this.serverGeneration = serverGeneration;
    }

    /** Connect at stage 0, as a listener, with no consumer filter. */
    public static FsMetaDaemonClient connect(Path socket, long fromBatch) throws IOException {
        return connect(socket, fromBatch, 0L, 0, false, List.of(), List.of());
    }

    /**
     * Connect with the staged-build header.
     *
     * @param socket the root's Unix socket
     * @param fromBatch the last root batch applied, or {@link #LATEST}
     * @param fromStageBatch the last producer-stage batch applied (0 for "from the beginning")
     * @param stage the stage this client consumes (0 is the ordinary source stream)
     * @param builder whether this subscriber acknowledges batches and therefore blocks its successor
     * @param include consumer include patterns (empty means pass-all)
     * @param exclude consumer exclude patterns (exclude wins)
     */
    public static FsMetaDaemonClient connect(Path socket, long fromBatch, long fromStageBatch, int stage,
            boolean builder, List<String> include, List<String> exclude) throws IOException {
        return open(socket, fromBatch, fromStageBatch, stage, builder, include, exclude, true);
    }

    /** Connect with `SUBSCRIBE_V2`: no `from_stage_batch` cursor, so the producer stage starts at its head. */
    public static FsMetaDaemonClient connectV2(Path socket, long fromBatch, int stage, boolean builder,
            List<String> include, List<String> exclude) throws IOException {
        return open(socket, fromBatch, 0, stage, builder, include, exclude, false);
    }

    private static FsMetaDaemonClient open(Path socket, long fromBatch, long fromStageBatch, int stage,
            boolean builder, List<String> include, List<String> exclude, boolean v3) throws IOException {
        if (stage < 0 || stage > MAX_STAGE) throw new IllegalArgumentException("stage outside 0.." + MAX_STAGE);
        SocketChannel channel = SocketChannel.open(StandardProtocolFamily.UNIX);
        try {
            channel.connect(UnixDomainSocketAddress.of(socket));
            writeFrame(channel, KIND_HELLO, hello());
            Frame greeting = readFrame(channel);
            if (greeting.kind != KIND_HELLO || greeting.payload.length != HELLO_SIZE) {
                throw new IOException("fs-meta: expected a 24-byte HELLO, got kind 0x"
                        + Integer.toHexString(greeting.kind));
            }
            ByteBuffer hello = littleEndian(greeting.payload);
            int protocol = Short.toUnsignedInt(hello.getShort());
            int entrySize = Short.toUnsignedInt(hello.getShort());
            int hash = Byte.toUnsignedInt(hello.get());
            hello.position(8); // role, capabilities and reserved are bytes 5..7
            long generation = hello.getLong();
            if ((protocol >>> 8) != (PROTOCOL >>> 8)) {
                throw new IOException("fs-meta: daemon speaks protocol 0x" + Integer.toHexString(protocol));
            }
            if (entrySize != ENTRY_SIZE) throw new IOException("fs-meta: daemon entry size " + entrySize);
            if (hash != 0) throw new IOException("fs-meta: daemon hash algorithm " + hash);
            long subscribeFrom = fromBatch == LATEST ? generation : fromBatch;
            writeFrame(channel, v3 ? KIND_SUBSCRIBE_V3 : 0x0b,
                    v3
                            ? subscribeV3(subscribeFrom, fromStageBatch, stage, builder, include, exclude)
                            : subscribeV2(subscribeFrom, stage, builder, include, exclude));
            return new FsMetaDaemonClient(channel, stage, generation);
        } catch (IOException | RuntimeException failure) {
            channel.close();
            throw failure;
        }
    }

    /** The generation named in the daemon's greeting. */
    public long serverGeneration() {
        return serverGeneration;
    }

    /** Read one event. {@code PING}/{@code PONG} are handled internally and never returned. */
    public Event nextEvent() throws IOException {
        while (true) {
            Frame frame = readFrame(channel);
            switch (frame.kind) {
                case KIND_HELLO -> throw new IOException("fs-meta: a second HELLO is not part of the protocol");
                case KIND_STATE -> {
                    if (frame.payload.length != 14) throw new IOException("fs-meta: short STATE");
                    ByteBuffer payload = littleEndian(frame.payload);
                    return new StateEvent(
                            Byte.toUnsignedInt(payload.get()),
                            Byte.toUnsignedInt(payload.get()),
                            payload.getInt(),
                            payload.getLong());
                }
                case KIND_GIT_EVENT -> {
                    if (frame.payload.length < 8) throw new IOException("fs-meta: short GIT_EVENT");
                    return new GitEvent(Byte.toUnsignedInt(frame.payload[0]));
                }
                case KIND_PING -> writeFrame(channel, KIND_PONG, new byte[0]);
                case KIND_PONG -> {
                    // A reply to a keepalive; not an application event.
                }
                case KIND_START_BATCH -> {
                    if (frame.payload.length != 16) throw new IOException("fs-meta: short START_BATCH");
                    ByteBuffer payload = littleEndian(frame.payload);
                    return new BatchStart(payload.getLong(), payload.getLong());
                }
                case KIND_CHANGE_ENTRY -> {
                    Change change = change(frame.payload);
                    return new ChangeEvent(change.name, change.flags);
                }
                case KIND_END_BATCH -> {
                    if (frame.payload.length != 40) throw new IOException("fs-meta: short END_BATCH");
                    ByteBuffer payload = littleEndian(frame.payload);
                    return new BatchEnd(payload.getLong(), payload.getLong(), payload.getLong(),
                            payload.getLong(), payload.getLong());
                }
                case KIND_STAGE_READY -> {
                    if (frame.payload.length != 18) throw new IOException("fs-meta: short STAGE_READY");
                    ByteBuffer payload = littleEndian(frame.payload);
                    return new StageReady(Short.toUnsignedInt(payload.getShort()), payload.getLong(),
                            payload.getLong());
                }
                case KIND_STAGE_BATCH_START -> {
                    if (frame.payload.length != 26) throw new IOException("fs-meta: short STAGE_BATCH_START");
                    ByteBuffer payload = littleEndian(frame.payload);
                    currentStage = Short.toUnsignedInt(payload.getShort());
                    return new StageBatchStart(currentStage, payload.getLong(), payload.getLong(),
                            payload.getLong());
                }
                case KIND_STAGE_CHANGE_ENTRY -> {
                    Change change = change(frame.payload);
                    return new StageChangeEvent(currentStage, change.name, change.flags);
                }
                case KIND_STAGE_BATCH_END -> {
                    if (frame.payload.length != 43) throw new IOException("fs-meta: short STAGE_BATCH_END");
                    ByteBuffer payload = littleEndian(frame.payload);
                    int endStage = Short.toUnsignedInt(payload.getShort());
                    return new StageBatchEnd(endStage, payload.getLong(), payload.getLong(),
                            payload.getLong(), payload.getLong(), payload.getLong(),
                            Byte.toUnsignedInt(payload.get()));
                }
                case KIND_ERROR -> {
                    if (frame.payload.length < 2) throw new IOException("fs-meta: short ERROR");
                    int code = Short.toUnsignedInt(littleEndian(frame.payload).getShort());
                    String detail = new String(frame.payload, 2, frame.payload.length - 2,
                            StandardCharsets.UTF_8);
                    throw new ProtocolException(code, detail);
                }
                default -> throw new IOException("fs-meta: unknown frame kind 0x"
                        + Integer.toHexString(frame.kind));
            }
        }
    }

    /** Announce that this builder is working from {@code generation}. */
    public void sendBuildStarted(long generation) throws IOException {
        ByteBuffer payload = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN);
        payload.putLong(generation);
        writeFrame(channel, 0x0c, payload.array());
    }

    /** Acknowledge through {@code generation}; status is {@link #BUILD_OK}, {@link #BUILD_FAILED} or
     * {@link #BUILD_CANCELLED}. */
    public void sendBuildDone(long generation, int status) throws IOException {
        if (status != BUILD_OK && status != BUILD_FAILED && status != BUILD_CANCELLED) {
            throw new IllegalArgumentException("unknown build status " + status);
        }
        ByteBuffer payload = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN);
        payload.putLong(generation);
        payload.put((byte) status);
        writeFrame(channel, 0x0d, payload.array());
    }

    @Override
    public void close() throws IOException {
        channel.close();
    }

    // ---------------------------------------------------------------- events

    /** One server frame, decoded. */
    public sealed interface Event permits BatchStart, ChangeEvent, BatchEnd, StateEvent, GitEvent, StageReady,
            StageBatchStart, StageChangeEvent, StageBatchEnd {
    }

    public record BatchStart(long generation, long parent) implements Event {
    }

    public record ChangeEvent(String name, int flags) implements Event {
    }

    public record BatchEnd(long generation, long added, long changed, long deleted, long changesHash)
            implements Event {
    }

    public record StateEvent(int state, int reason, int idleTimeoutMs, long headBatch) implements Event {
        public boolean settled() {
            return state == STATE_OFF || state == STATE_WATCHING;
        }
    }

    public record GitEvent(int kind) implements Event {
    }

    public record StageReady(int stage, long headBatch, long releasedThrough) implements Event {
    }

    public record StageBatchStart(int stage, long generation, long parent, long startedNs) implements Event {
    }

    public record StageChangeEvent(int stage, String name, int flags) implements Event {
    }

    public record StageBatchEnd(int stage, long generation, long added, long changed, long deleted,
            long changesHash, int status) implements Event {
    }

    /** An {@code ERROR} frame, with the numeric code and the wire word. */
    public static final class ProtocolException extends IOException {
        private final int code;

        ProtocolException(int code, String detail) {
            super("fs-meta: " + word(code) + (detail.isBlank() ? "" : ": " + detail));
            this.code = code;
        }

        public int code() {
            return code;
        }

        public String word() {
            return word(code);
        }

        private static String word(int code) {
            return switch (code) {
                case ERROR_PROTOCOL -> "protocol";
                case ERROR_BATCH_TOO_OLD -> "batch-too-old";
                case ERROR_BATCH_GAP -> "batch-gap";
                default -> "error-" + code;
            };
        }
    }

    // ---------------------------------------------------------------- frames

    private record Frame(int kind, byte[] payload) {
    }

    private record Change(String name, int flags) {
    }

    private static byte[] hello() {
        ByteBuffer payload = ByteBuffer.allocate(HELLO_SIZE).order(ByteOrder.LITTLE_ENDIAN);
        payload.putShort((short) PROTOCOL);
        payload.putShort((short) ENTRY_SIZE);
        payload.put((byte) 0); // wyhash64
        payload.put((byte) 1); // client
        payload.put((byte) 0); // capabilities
        payload.put((byte) 0); // reserved
        payload.putLong(0);
        payload.putLong(MAX_FRAME);
        return payload.array();
    }

    private static byte[] subscribeV2(long fromBatch, int stage, boolean builder,
            List<String> include, List<String> exclude) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ByteBuffer head = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN);
        head.putLong(fromBatch);
        head.putShort((short) stage);
        head.putShort((short) (builder ? 1 : 0));
        out.writeBytes(head.array());
        writePatterns(out, include);
        writePatterns(out, exclude);
        return out.toByteArray();
    }

    private static byte[] subscribeV3(long fromBatch, long fromStageBatch, int stage, boolean builder,
            List<String> include, List<String> exclude) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ByteBuffer head = ByteBuffer.allocate(20).order(ByteOrder.LITTLE_ENDIAN);
        head.putLong(fromBatch);
        head.putLong(fromStageBatch);
        head.putShort((short) stage);
        head.putShort((short) (builder ? 1 : 0));
        out.writeBytes(head.array());
        writePatterns(out, include);
        writePatterns(out, exclude);
        return out.toByteArray();
    }

    private static void writePatterns(ByteArrayOutputStream out, List<String> patterns) {
        ByteBuffer count = ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN);
        count.putShort((short) patterns.size());
        out.writeBytes(count.array());
        for (String pattern : patterns) {
            byte[] bytes = pattern.getBytes(StandardCharsets.UTF_8);
            if (bytes.length > 0xffff) throw new IllegalArgumentException("pattern too long");
            ByteBuffer length = ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN);
            length.putShort((short) bytes.length);
            out.writeBytes(length.array());
            out.writeBytes(bytes);
        }
    }

    private static Change change(byte[] payload) throws IOException {
        if (payload.length < ENTRY_SIZE) throw new IOException("fs-meta: short CHANGE_ENTRY");
        ByteBuffer entry = littleEndian(payload);
        entry.position(40);
        int nameLength = entry.getInt();
        int flags = entry.getInt();
        if (nameLength < 0 || ENTRY_SIZE + nameLength > payload.length) {
            throw new IOException("fs-meta: CHANGE_ENTRY name length " + nameLength);
        }
        String name = new String(payload, ENTRY_SIZE, nameLength, StandardCharsets.UTF_8);
        return new Change(name, flags);
    }

    private static Frame readFrame(SocketChannel channel) throws IOException {
        ByteBuffer header = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN);
        readFully(channel, header);
        int kind = Short.toUnsignedInt(header.getShort());
        int flags = Short.toUnsignedInt(header.getShort());
        int length = header.getInt();
        if (length < 0 || length > MAX_FRAME) throw new IOException("fs-meta: frame length " + length);
        if (flags != 0) throw new IOException("fs-meta: frame flags 0x" + Integer.toHexString(flags));
        ByteBuffer payload = ByteBuffer.allocate(length);
        readFully(channel, payload);
        return new Frame(kind, payload.array());
    }

    private static void writeFrame(SocketChannel channel, int kind, byte[] payload) throws IOException {
        ByteBuffer frame = ByteBuffer.allocate(8 + payload.length).order(ByteOrder.LITTLE_ENDIAN);
        frame.putShort((short) kind);
        frame.putShort((short) 0);
        frame.putInt(payload.length);
        frame.put(payload);
        frame.flip();
        while (frame.hasRemaining()) channel.write(frame);
    }

    private static void readFully(SocketChannel channel, ByteBuffer buffer) throws IOException {
        while (buffer.hasRemaining()) {
            if (channel.read(buffer) < 0) throw new EOFException("fs-meta: daemon closed the connection");
        }
        buffer.flip();
    }

    private static ByteBuffer littleEndian(byte[] bytes) {
        return ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
    }
}
