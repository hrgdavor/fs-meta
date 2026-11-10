// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.io.EOFException;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The Java client's staged-build surface, against a fake Unix-socket server. Unix domain sockets are a JDK/OS
 * feature; the test skips where the platform refuses them, exactly like the daemon integration tests.
 */
class FsMetaDaemonClientTest {

    @Test
    void subscribeV3AndStageFramesAreDecodedAndBuildControlIsSent() throws Exception {
        try (FakeServer server = FakeServer.start()) {
            List<byte[]> control = new ArrayList<>();
            AtomicReference<Throwable> serverFailure = new AtomicReference<>();
            Thread peer = new Thread(() -> {
                try (SocketChannel channel = server.accept()) {
                    Frame hello = readFrame(channel);
                    assertEquals(0x01, hello.kind);
                    writeFrame(channel, 0x01, helloPayload(7));

                    Frame subscribe = readFrame(channel);
                    assertEquals(0x12, subscribe.kind);
                    ByteBuffer head = little(subscribe.payload);
                    assertEquals(3L, head.getLong());
                    assertEquals(2L, head.getLong());
                    assertEquals(1, Short.toUnsignedInt(head.getShort()));
                    assertEquals(1, Short.toUnsignedInt(head.getShort()));

                    ByteBuffer ready = little(new byte[18]);
                    ready.putShort((short) 1);
                    ready.putLong(7);
                    ready.putLong(6);
                    writeFrame(channel, 0x0e, ready.array());

                    ByteBuffer start = little(new byte[26]);
                    start.putShort((short) 1);
                    start.putLong(2);
                    start.putLong(1);
                    writeFrame(channel, 0x0f, start.array());

                    writeFrame(channel, 0x10, entry("build/classes/A.class", 0x20 | 0x02));

                    ByteBuffer end = little(new byte[43]);
                    end.putShort((short) 1);
                    end.putLong(2);
                    end.putLong(1);
                    writeFrame(channel, 0x11, end.array());

                    control.add(readFrame(channel).payload);
                    control.add(readFrame(channel).payload);
                } catch (Throwable failure) {
                    serverFailure.set(failure);
                }
            });
            peer.start();

            try (FsMetaDaemonClient client = FsMetaDaemonClient.connect(server.path, 3, 2, 1, true,
                    List.of(), List.of())) {
                assertEquals(7, client.serverGeneration());
                FsMetaDaemonClient.StageReady ready = (FsMetaDaemonClient.StageReady) client.nextEvent();
                assertEquals(1, ready.stage());
                assertEquals(7, ready.headBatch());
                assertEquals(6, ready.releasedThrough());

                FsMetaDaemonClient.StageBatchStart start = (FsMetaDaemonClient.StageBatchStart) client.nextEvent();
                assertEquals(2, start.generation());
                assertEquals(1, start.parent());

                FsMetaDaemonClient.StageChangeEvent change = (FsMetaDaemonClient.StageChangeEvent) client.nextEvent();
                assertEquals(1, change.stage());
                assertEquals("build/classes/A.class", change.name());
                assertEquals(0x20 | 0x02, change.flags());

                FsMetaDaemonClient.StageBatchEnd end = (FsMetaDaemonClient.StageBatchEnd) client.nextEvent();
                assertEquals(1, end.added());
                assertEquals(2, end.generation());

                client.sendBuildStarted(2);
                client.sendBuildDone(2, FsMetaDaemonClient.BUILD_OK);
            }
            peer.join(5000);
            if (serverFailure.get() != null) throw new AssertionError(serverFailure.get());
            assertEquals(8, control.get(0).length);
            assertEquals(9, control.get(1).length);
            assertTrue(little(control.get(1)).get(8) == 0);
        } catch (UnsupportedOperationException | IOException unsupported) {
            Assumptions.abort("Unix domain sockets are unavailable on this host: " + unsupported.getMessage());
        }
    }

    @Test
    void subscribeV2CarriesTheStageWithoutAStageCursor() throws Exception {
        try (FakeServer server = FakeServer.start()) {
            AtomicReference<Throwable> serverFailure = new AtomicReference<>();
            AtomicReference<byte[]> subscribe = new AtomicReference<>();
            Thread peer = new Thread(() -> {
                try (SocketChannel channel = server.accept()) {
                    assertEquals(0x01, readFrame(channel).kind);
                    writeFrame(channel, 0x01, helloPayload(5));
                    Frame frame = readFrame(channel);
                    assertEquals(0x0b, frame.kind);
                    subscribe.set(frame.payload);
                } catch (Throwable failure) {
                    serverFailure.set(failure);
                }
            });
            peer.start();
            try (FsMetaDaemonClient client = FsMetaDaemonClient.connectV2(server.path, 4, 3, true,
                    List.of(), List.of())) {
                assertEquals(5, client.serverGeneration());
            }
            peer.join(5000);
            if (serverFailure.get() != null) throw new AssertionError(serverFailure.get());
            ByteBuffer payload = little(subscribe.get());
            assertEquals(4L, payload.getLong());
            assertEquals(3, Short.toUnsignedInt(payload.getShort()));
            assertEquals(1, Short.toUnsignedInt(payload.getShort()));
        } catch (UnsupportedOperationException | IOException unsupported) {
            Assumptions.abort("Unix domain sockets are unavailable on this host: " + unsupported.getMessage());
        }
    }

    private static byte[] helloPayload(long generation) {
        ByteBuffer payload = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN);
        payload.putShort((short) 0x0105);
        payload.putShort((short) 64);
        payload.put((byte) 0);
        payload.put((byte) 0); // server
        payload.put((byte) 0);
        payload.put((byte) 0);
        payload.putLong(generation);
        payload.putLong(1 << 20);
        return payload.array();
    }

    private static byte[] entry(String name, int flags) {
        byte[] bytes = name.getBytes(StandardCharsets.UTF_8);
        ByteBuffer payload = ByteBuffer.allocate(64 + bytes.length).order(ByteOrder.LITTLE_ENDIAN);
        payload.position(40);
        payload.putInt(bytes.length);
        payload.putInt(flags);
        payload.position(64);
        payload.put(bytes);
        return payload.array();
    }

    private record Frame(int kind, byte[] payload) {
    }

    private static Frame readFrame(SocketChannel channel) throws IOException {
        ByteBuffer header = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN);
        readFully(channel, header);
        int kind = Short.toUnsignedInt(header.getShort());
        header.getShort();
        int length = header.getInt();
        ByteBuffer payload = ByteBuffer.allocate(length);
        readFully(channel, payload);
        return new Frame(kind, payload.array());
    }

    private static void readFully(SocketChannel channel, ByteBuffer buffer) throws IOException {
        while (buffer.hasRemaining()) {
            if (channel.read(buffer) < 0) throw new EOFException("peer closed");
        }
        buffer.flip();
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

    private static ByteBuffer little(byte[] bytes) {
        return ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
    }

    private static final class FakeServer implements AutoCloseable {
        private final Path directory;
        private final Path path;
        private final ServerSocketChannel server;

        private FakeServer(Path directory, Path path, ServerSocketChannel server) {
            this.directory = directory;
            this.path = path;
            this.server = server;
        }

        static FakeServer start() throws IOException {
            Path directory = Files.createTempDirectory("fsmeta-daemon-client-");
            Path path = directory.resolve("root.sock");
            ServerSocketChannel server = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
            server.bind(UnixDomainSocketAddress.of(path));
            return new FakeServer(directory, path, server);
        }

        SocketChannel accept() throws IOException {
            return server.accept();
        }

        @Override
        public void close() throws IOException {
            server.close();
            Files.deleteIfExists(path);
            Files.deleteIfExists(directory);
        }
    }
}
