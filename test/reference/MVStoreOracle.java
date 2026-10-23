import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import org.h2.mvstore.DataUtils;
import org.h2.mvstore.MVMap;
import org.h2.mvstore.MVStore;
import org.h2.mvstore.MVStoreException;
import org.h2.mvstore.WriteBuffer;
import org.h2.mvstore.type.LongDataType;
import org.h2.mvstore.type.StringDataType;

public class MVStoreOracle {
    private static final String WORDS = "words, \"Unicode\"";

    private static MVMap<String, String> words(MVStore store) {
        return store.openMap(WORDS, new MVMap.Builder<String, String>()
                .keyType(StringDataType.INSTANCE).valueType(StringDataType.INSTANCE));
    }

    private static MVMap<Long, Long> longs(MVStore store) {
        return store.openMap("longs", new MVMap.Builder<Long, Long>()
                .keyType(LongDataType.INSTANCE).valueType(LongDataType.INSTANCE));
    }

    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder();
        for (byte value : bytes) {
            result.append(String.format("%02x", value & 255));
        }
        return result.toString();
    }

    private static String utf16(String text) {
        ByteBuffer buffer = ByteBuffer.allocate(text.length() * 2);
        for (int index = 0; index < text.length(); index++) {
            buffer.putChar(text.charAt(index));
        }
        return hex(buffer.array());
    }

    private static void create(String path, int compression) {
        MVStore.Builder builder = new MVStore.Builder().fileName(path).autoCommitDisabled()
                .autoCompactFillRate(0).keysPerPage(8).pageSplitSize(512);
        if (compression == 1) {
            builder.compress();
        } else if (compression == 2) {
            builder.compressHigh();
        }
        try (MVStore store = builder.open()) {
            store.setRetentionTime(Integer.MAX_VALUE);
            MVMap<String, String> words = words(store);
            words.put("", "empty");
            words.put("ascii", "value");
            words.put("nul\0key", "zero\0");
            words.put("café", "árbol");
            words.put("中文", "漢字");
            words.put("\uffff", "last-bmp");
            words.put("\ud83d\ude00", "\ud83d\ude00");
            for (int i = 0; i < 128; i++) {
                words.put(String.format("key-%03d", i), "record " + i + " " + "abcdefg".repeat(80));
            }
            words.put("repeat", "abc".repeat(2000));
            MVMap<Long, Long> longs = longs(store);
            long[] numbers = {Long.MIN_VALUE, -123456789, -1, 0, 1, 127, 128, Long.MAX_VALUE};
            for (long value : numbers) {
                longs.put(value, ~value);
            }
            store.commit();
            words.remove("key-000");
            words.put("key-001", "updated before close");
            words.put("later", "second commit");
            store.commit();
        }
    }

    private static void dump(String path) {
        try (MVStore store = new MVStore.Builder().fileName(path).readOnly().open()) {
            for (Map.Entry<String, String> entry : words(store).entrySet()) {
                if (!entry.getValue().equals(words(store).get(entry.getKey()))) {
                    throw new IllegalStateException("String B-tree lookup mismatch");
                }
                System.out.println("S\t" + utf16(entry.getKey()) + "\t" + utf16(entry.getValue()));
            }
            for (Map.Entry<Long, Long> entry : longs(store).entrySet()) {
                if (!entry.getValue().equals(longs(store).get(entry.getKey()))) {
                    throw new IllegalStateException("Long B-tree lookup mismatch");
                }
                System.out.println("L\t" + entry.getKey() + "\t" + entry.getValue());
            }
        }
    }

    private static void golden() {
        int[] ints = {0, 1, 127, 128, 16383, 16384, 2097151, 2097152, 268435455, 268435456,
                Integer.MAX_VALUE, Integer.MIN_VALUE, -1};
        for (int value : ints) {
            ByteBuffer buffer = ByteBuffer.allocate(5);
            DataUtils.writeVarInt(buffer, value);
            System.out.println("I\t" + value + "\t" + hex(java.util.Arrays.copyOf(buffer.array(), buffer.position())));
        }
        long[] longs = {0, 1, 127, 128, 16384, 2097151, 268435456, Long.MAX_VALUE, Long.MIN_VALUE, -1};
        for (long value : longs) {
            ByteBuffer buffer = ByteBuffer.allocate(10);
            DataUtils.writeVarLong(buffer, value);
            System.out.println("L\t" + value + "\t" + hex(java.util.Arrays.copyOf(buffer.array(), buffer.position())));
        }
        String[] strings = {"", "abc", "a\0b", "café", "中文", "\ud83d\ude00", "\ud800", "\udfff"};
        for (String value : strings) {
            WriteBuffer buffer = new WriteBuffer();
            StringDataType.INSTANCE.write(buffer, value);
            ByteBuffer bytes = buffer.getBuffer();
            byte[] data = new byte[bytes.position()];
            bytes.rewind().get(data);
            System.out.println("S\t" + utf16(value) + "\t" + hex(data));
        }
        for (int length : new int[] {0, 1, 2, 3, 32, 33, 48, 49, 64, 65, 1048576, 1048577, 5000000}) {
            int code = DataUtils.encodeLength(length);
            System.out.println("P\t" + length + "\t" + code + "\t" + DataUtils.decodePageLength(code));
        }
        for (String value : new String[] {"", "a", "ab", "abc", "abcdefgh", "checksum".repeat(1000)}) {
            byte[] bytes = value.getBytes(StandardCharsets.ISO_8859_1);
            System.out.println("F\t" + hex(bytes) + "\t" + Integer.toUnsignedString(DataUtils.getFletcher32(bytes, 0, bytes.length)));
        }
    }

    public static void main(String[] arguments) throws Exception {
        String operation = arguments[0];
        if (operation.equals("golden")) {
            golden();
        } else if (operation.equals("create")) {
            create(arguments[1], Integer.parseInt(arguments[2]));
        } else if (operation.equals("dump")) {
            dump(arguments[1]);
        } else if (operation.equals("mutate")) {
            try (MVStore store = new MVStore.Builder().fileName(arguments[1]).autoCommitDisabled().autoCompactFillRate(0).open()) {
                words(store).put("java", "after ruby");
                words(store).remove("key-003");
                longs(store).put(9L, -9L);
                store.commit();
            }
        } else if (operation.equals("lock")) {
            try (MVStore store = new MVStore.Builder().fileName(arguments[1]).autoCommitDisabled().open()) {
                System.out.println("LOCKED");
                System.out.flush();
                System.in.read();
            } catch (MVStoreException error) {
                System.out.println("ERROR " + error.getErrorCode());
            }
        } else if (operation.equals("sql")) {
            try (java.sql.Connection connection = java.sql.DriverManager.getConnection("jdbc:h2:" + arguments[1], "sa", "")) {
                connection.createStatement().execute("CREATE TABLE TEST(ID INT PRIMARY KEY, V VARCHAR)");
                connection.createStatement().execute("INSERT INTO TEST VALUES (1, 'native storage reference')");
                connection.createStatement().execute("CREATE INDEX TEST_V ON TEST(V)");
            }
        } else {
            throw new IllegalArgumentException(operation);
        }
    }
}
