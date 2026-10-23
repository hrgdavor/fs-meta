// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.fsmeta;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * A small, strict JSON reader and writer, for the sidekick document and the conformance vectors.
 *
 * <h3>Why this module does not use Jackson</h3>
 * <p>{@code fs-meta} is meant to be embedded: a tool that keeps an index over a codebase should be able to
 * depend on the format and nothing else. Jackson is a fine library and the rest of this reactor uses it
 * freely, but it is 2 MB of API for one document of seventeen keys, and the watcher family it serves has
 * its own rule about not taking this workspace's dependencies (AGENTS.md § 2). The engine's
 * {@code jcodebuddy-generated} takes the same posture for three types, and this class is the same trade:
 * a strict parser for a known shape, with tests that pin what it accepts and what it refuses.</p>
 *
 * <h3>What it accepts, and what it refuses</h3>
 * <p>The object/array/string/number/boolean/null grammar of RFC 8259 and nothing else: no comments, no
 * trailing commas, no single quotes, no unquoted keys, no {@code NaN}/{@code Infinity}, no content after
 * the top-level value, and no nesting past {@value #MAX_DEPTH}. Integral numbers become {@link Long},
 * everything else {@link Double}. Objects are {@link LinkedHashMap}s, so a document's key order survives a
 * read/write round trip — which is what {@code FORMAT.md} § 7 asks of the keys a reader does not
 * understand.</p>
 */
final class Json {

    /** Deep enough for any document this format defines, shallow enough that a hostile file cannot blow the stack. */
    static final int MAX_DEPTH = 64;

    private final String text;
    private int at;

    private Json(String text) {
        this.text = text;
    }

    /** Parses {@code text} as one JSON value. */
    static Object parse(String text) {
        Json parser = new Json(text);
        parser.skipWhitespace();
        Object value = parser.readValue(0);
        parser.skipWhitespace();
        if (parser.at != text.length()) {
            throw parser.fail("unexpected content after the JSON value");
        }
        return value;
    }

    /** Serialises {@code value} compactly. */
    static String write(Object value) {
        StringBuilder out = new StringBuilder();
        writeValue(out, value);
        return out.toString();
    }

    // ------------------------------------------------------------------ reading

    private Object readValue(int depth) {
        if (depth > MAX_DEPTH) {
            throw fail("nesting is deeper than " + MAX_DEPTH + " levels");
        }
        if (at >= text.length()) {
            throw fail("the document ends where a value was expected");
        }
        char c = text.charAt(at);
        return switch (c) {
            case '{' -> readObject(depth);
            case '[' -> readArray(depth);
            case '"' -> readString();
            case 't' -> readLiteral("true", Boolean.TRUE);
            case 'f' -> readLiteral("false", Boolean.FALSE);
            case 'n' -> readLiteral("null", null);
            default -> readNumber();
        };
    }

    private Map<String, Object> readObject(int depth) {
        Map<String, Object> object = new LinkedHashMap<>();
        at++; // '{'
        skipWhitespace();
        if (peek() == '}') {
            at++;
            return object;
        }
        while (true) {
            skipWhitespace();
            if (peek() != '"') {
                throw fail("an object key must be a string");
            }
            String key = readString();
            skipWhitespace();
            if (peek() != ':') {
                throw fail("expected ':' after an object key");
            }
            at++;
            skipWhitespace();
            object.put(key, readValue(depth + 1));
            skipWhitespace();
            char next = peek();
            if (next == ',') {
                at++;
                continue;
            }
            if (next == '}') {
                at++;
                return object;
            }
            throw fail("expected ',' or '}' in an object");
        }
    }

    private List<Object> readArray(int depth) {
        List<Object> array = new ArrayList<>();
        at++; // '['
        skipWhitespace();
        if (peek() == ']') {
            at++;
            return array;
        }
        while (true) {
            skipWhitespace();
            array.add(readValue(depth + 1));
            skipWhitespace();
            char next = peek();
            if (next == ',') {
                at++;
                continue;
            }
            if (next == ']') {
                at++;
                return array;
            }
            throw fail("expected ',' or ']' in an array");
        }
    }

    private String readString() {
        at++; // '"'
        StringBuilder out = new StringBuilder();
        while (true) {
            if (at >= text.length()) {
                throw fail("the string is not closed");
            }
            char c = text.charAt(at++);
            if (c == '"') {
                return out.toString();
            }
            if (c != '\\') {
                if (c < 0x20) {
                    throw fail("an unescaped control character (0x" + Integer.toHexString(c) + ") in a string");
                }
                out.append(c);
                continue;
            }
            if (at >= text.length()) {
                throw fail("an escape is not finished");
            }
            char escape = text.charAt(at++);
            switch (escape) {
                case '"' -> out.append('"');
                case '\\' -> out.append('\\');
                case '/' -> out.append('/');
                case 'b' -> out.append('\b');
                case 'f' -> out.append('\f');
                case 'n' -> out.append('\n');
                case 'r' -> out.append('\r');
                case 't' -> out.append('\t');
                case 'u' -> out.append(readUnicodeEscape());
                default -> throw fail("unknown escape '\\" + escape + "'");
            }
        }
    }

    private char readUnicodeEscape() {
        if (at + 4 > text.length()) {
            throw fail("a \\u escape needs four hex digits");
        }
        int value = 0;
        for (int i = 0; i < 4; i++) {
            int digit = Character.digit(text.charAt(at + i), 16);
            if (digit < 0) {
                throw fail("a \\u escape needs four hex digits");
            }
            value = (value << 4) | digit;
        }
        at += 4;
        return (char) value;
    }

    private Object readLiteral(String literal, Object value) {
        if (!text.startsWith(literal, at)) {
            throw fail("expected '" + literal + "'");
        }
        at += literal.length();
        return value;
    }

    private Object readNumber() {
        int start = at;
        if (peek() == '-') {
            at++;
        }
        if (at >= text.length() || !isDigit(peek())) {
            throw fail("expected a number");
        }
        if (peek() == '0') {
            at++;
        } else {
            while (at < text.length() && isDigit(peek())) {
                at++;
            }
        }
        boolean integral = true;
        if (at < text.length() && peek() == '.') {
            integral = false;
            at++;
            if (at >= text.length() || !isDigit(peek())) {
                throw fail("a fraction needs at least one digit");
            }
            while (at < text.length() && isDigit(peek())) {
                at++;
            }
        }
        if (at < text.length() && (peek() == 'e' || peek() == 'E')) {
            integral = false;
            at++;
            if (at < text.length() && (peek() == '+' || peek() == '-')) {
                at++;
            }
            if (at >= text.length() || !isDigit(peek())) {
                throw fail("an exponent needs at least one digit");
            }
            while (at < text.length() && isDigit(peek())) {
                at++;
            }
        }
        String literal = text.substring(start, at);
        if (integral) {
            try {
                return Long.parseLong(literal);
            } catch (NumberFormatException overflow) {
                // Fall through: a value too large for a long is still a legal JSON number.
            }
        }
        double value = Double.parseDouble(literal);
        if (Double.isNaN(value) || Double.isInfinite(value)) {
            throw fail("a number that is not finite is not JSON: " + literal);
        }
        return value;
    }

    private char peek() {
        return at < text.length() ? text.charAt(at) : '\0';
    }

    private void skipWhitespace() {
        while (at < text.length()) {
            char c = text.charAt(at);
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                at++;
            } else {
                return;
            }
        }
    }

    private IllegalArgumentException fail(String message) {
        int line = 1;
        int column = 1;
        for (int i = 0; i < Math.min(at, text.length()); i++) {
            if (text.charAt(i) == '\n') {
                line++;
                column = 1;
            } else {
                column++;
            }
        }
        return new IllegalArgumentException("not valid JSON at line " + line + ", column " + column + ": " + message);
    }

    private static boolean isDigit(char c) {
        return c >= '0' && c <= '9';
    }

    // ------------------------------------------------------------------ writing

    private static void writeValue(StringBuilder out, Object value) {
        if (value == null) {
            out.append("null");
        } else if (value instanceof String text) {
            writeString(out, text);
        } else if (value instanceof Boolean flag) {
            out.append(flag ? "true" : "false");
        } else if (value instanceof Long || value instanceof Integer || value instanceof Short || value instanceof Byte) {
            out.append(((Number) value).longValue());
        } else if (value instanceof Double || value instanceof Float) {
            double number = ((Number) value).doubleValue();
            if (number == Math.rint(number) && !Double.isInfinite(number) && Math.abs(number) < 1e15) {
                out.append((long) number);
            } else {
                out.append(number);
            }
        } else if (value instanceof Map<?, ?> map) {
            out.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (!first) {
                    out.append(',');
                }
                first = false;
                writeString(out, String.valueOf(entry.getKey()));
                out.append(':');
                writeValue(out, entry.getValue());
            }
            out.append('}');
        } else if (value instanceof Iterable<?> iterable) {
            out.append('[');
            boolean first = true;
            for (Object element : iterable) {
                if (!first) {
                    out.append(',');
                }
                first = false;
                writeValue(out, element);
            }
            out.append(']');
        } else {
            throw new IllegalArgumentException("cannot write a " + value.getClass().getName() + " as JSON");
        }
    }

    private static void writeString(StringBuilder out, String text) {
        out.append('"');
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            switch (c) {
                case '"' -> out.append("\\\"");
                case '\\' -> out.append("\\\\");
                case '\n' -> out.append("\\n");
                case '\r' -> out.append("\\r");
                case '\t' -> out.append("\\t");
                case '\b' -> out.append("\\b");
                case '\f' -> out.append("\\f");
                default -> {
                    if (c < 0x20) {
                        out.append(String.format("\\u%04x", (int) c));
                    } else {
                        out.append(c);
                    }
                }
            }
        }
        out.append('"');
    }
}
