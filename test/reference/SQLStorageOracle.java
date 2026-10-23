import java.math.BigDecimal;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
import org.h2.api.IntervalQualifier;
import org.h2.mvstore.WriteBuffer;
import org.h2.mvstore.db.ValueDataType;
import org.h2.mvstore.MVStore;
import org.h2.mvstore.tx.Transaction;
import org.h2.mvstore.tx.TransactionMap;
import org.h2.mvstore.tx.TransactionStore;
import org.h2.mvstore.type.LongDataType;
import org.h2.mvstore.type.MetaType;
import org.h2.mvstore.type.DataType;
import org.h2.mvstore.type.StringDataType;
import org.h2.mvstore.type.ByteArrayDataType;
import org.h2.mvstore.type.ObjectDataType;
import org.h2.mvstore.db.RowDataType;
import org.h2.mvstore.db.NullValueDataType;
import org.h2.mvstore.db.LobStorageMap;
import org.h2.mvstore.tx.VersionedValueType;
import org.h2.value.*;
import org.h2.value.lob.LobDataDatabase;
import org.h2.jdbc.JdbcResultSet;

public class SQLStorageOracle {
    private static byte[] bytes(WriteBuffer buffer) {
        ByteBuffer source = buffer.getBuffer();
        byte[] result = new byte[source.position()];
        source.rewind().get(result);
        return result;
    }

    private static String hex(byte[] bytes) {
        return java.util.HexFormat.of().formatHex(bytes);
    }

    private static void vectors() {
        List<Value> values = new ArrayList<>();
        values.add(ValueNull.INSTANCE);
        values.add(ValueBoolean.FALSE);
        values.add(ValueBoolean.TRUE);
        for (byte n : new byte[] {-128, -1, 0, 127}) values.add(ValueTinyint.get(n));
        for (short n : new short[] {-32768, -1, 0, 32767}) values.add(ValueSmallint.get(n));
        for (int n : new int[] {Integer.MIN_VALUE, -1, 0, 15, 16, 127, 128, Integer.MAX_VALUE}) values.add(ValueInteger.get(n));
        for (long n : new long[] {Long.MIN_VALUE, -1, 0, 7, 8, 127, 128, Long.MAX_VALUE}) values.add(ValueBigint.get(n));
        for (String s : new String[] {"0", "1", "0.00", "1.00", "-2", "-2.34", "9223372036854775807", "-9223372036854775808", "9223372036854775808", "-9223372036854775809", "123456789012345678901234567890.12300", "1E+12"}) {
            BigDecimal decimal = new BigDecimal(s);
            values.add(ValueNumeric.get(decimal.scale() < 0 ? decimal.setScale(0) : decimal));
            values.add(ValueDecfloat.get(new BigDecimal(s)));
        }
        values.add(ValueDecfloat.POSITIVE_INFINITY);
        values.add(ValueDecfloat.NEGATIVE_INFINITY);
        values.add(ValueDecfloat.NAN);
        for (double n : new double[] {-0.0, 0, 1, -1, 1.5, Math.PI, Double.MIN_VALUE, Double.MAX_VALUE, Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY}) {
            values.add(ValueDouble.get(n));
            values.add(ValueReal.get((float)n));
        }
        for (String s : new String[] {"", "a\0b", "café 中文 😀", "a".repeat(31), "b".repeat(32), "\ud800"}) {
            values.add(ValueVarchar.get(s));
            values.add(ValueChar.get(s));
            values.add(ValueVarcharIgnoreCase.get(s));
        }
        for (int length : new int[] {0, 1, 31, 32, 128}) {
            byte[] data = new byte[length];
            for (int i = 0; i < length; i++) data[i] = (byte)(i * 53);
            values.add(ValueVarbinary.get(data));
            values.add(ValueBinary.get(data));
            values.add(ValueJavaObject.getNoCopy(data));
            values.add(ValueBlob.createSmall(data));
        }
        values.add(ValueClob.createSmall("café 😀".getBytes(java.nio.charset.StandardCharsets.UTF_8), 7));
        values.add(new ValueBlob(new LobDataDatabase(null, 7, 999), 123456));
        values.add(new ValueClob(new LobDataDatabase(null, 7, 1000), 123456, 100000));
        values.add(ValueUuid.get(0x123456789abcdef0L, 0xfedcba9876543210L));
        values.add(ValueJson.fromJson("{\"a\":[true,null,1]}"));
        values.add(ValueGeometry.get("POINT (1 2)"));
        values.add(ValueDate.parse("2026-10-23"));
        values.add(ValueDate.parse("-0010-01-01"));
        values.add(ValueTime.parse("23:59:59.123456789", null));
        values.add(ValueTimeTimeZone.parse("12:13:14.123456789+05:45", null));
        values.add(ValueTimeTimeZone.parse("00:00:00-00:00:01", null));
        values.add(ValueTimestamp.parse("2026-10-23 12:34:56.123456789", null));
        values.add(ValueTimestampTimeZone.parse("2026-10-23 12:34:56.123456789+00:00:01", null));
        values.add(ValueTimestampTimeZone.parse("2026-10-23 12:34:56.123456789-03:00", null));
        for (IntervalQualifier q : IntervalQualifier.values()) {
            values.add(ValueInterval.from(q, false, 2, 0));
            values.add(ValueInterval.from(q, true, 2, 0));
        }
        values.add(ValueArray.get(new Value[] {ValueInteger.get(1), ValueNull.INSTANCE, ValueInteger.get(3)}, null));
        values.add(ValueRow.get(new Value[] {ValueInteger.get(1), ValueVarchar.get("nested"), ValueRow.get(new Value[] {ValueBoolean.TRUE})}));
        ValueDataType codec = new ValueDataType();
        for (int index = 0; index < values.size(); index++) {
            WriteBuffer buffer = new WriteBuffer();
            codec.write(buffer, values.get(index));
            System.out.println(index + "\t" + hex(bytes(buffer)));
        }
    }

    private static java.sql.Connection connection(String path, boolean readOnly) throws Exception {
        return java.sql.DriverManager.getConnection("jdbc:h2:" + path + (readOnly ? ";ACCESS_MODE_DATA=r;IFEXISTS=TRUE" : ""), "sa", "");
    }

    private static void metaVectors() {
        DataType<?>[] codecs = {StringDataType.INSTANCE, LongDataType.INSTANCE, ByteArrayDataType.INSTANCE,
                NullValueDataType.INSTANCE, new ValueDataType(), new VersionedValueType<Value, Object>(new ValueDataType()),
                new RowDataType(null, CompareMode.getInstance(null, 0), null, new int[] {0,1,4}, null, 3, true),
                new RowDataType(null, CompareMode.getInstance(null, 0), null, new int[] {5,2}, new int[] {2,0}, 4, true),
                new RowDataType(null, CompareMode.getInstance(null, 0), null, new int[] {0,0}, null, 2, false),
                new RowDataType(null, CompareMode.getInstance(null, 0), null, null, null, 0, true),
                LobStorageMap.BlobMeta.Type.INSTANCE, LobStorageMap.BlobReference.Type.INSTANCE, new ObjectDataType()};
        MetaType<Object> meta = new MetaType<>(null, null);
        for (int i = 0; i < codecs.length; i++) {
            WriteBuffer buffer = new WriteBuffer();
            meta.write(buffer, codecs[i]);
            System.out.println(i + "\t" + hex(bytes(buffer)));
        }
    }

    private static void createSQL(String path) throws Exception {
        try (java.sql.Connection connection = connection(path, false)) {
            java.sql.Statement statement = connection.createStatement();
            statement.execute("CREATE TABLE TEST(ID INT PRIMARY KEY, TXT VARCHAR, N NUMERIC(40,4), B BOOLEAN, T TINYINT, S SMALLINT, L BIGINT, R REAL, D DOUBLE, C CHAR(5), BIN VARBINARY, DT DATE, TM TIME(9), TS TIMESTAMP(9), TZ TIMESTAMP(9) WITH TIME ZONE, A INT ARRAY, RW ROW(X INT, Y VARCHAR), U UUID)");
            statement.execute("INSERT INTO TEST SELECT CAST(X AS INT), CASE WHEN MOD(X,17)=0 THEN NULL ELSE 'text-' || MOD(X,31) END, 12345678901234567890.1250 + X, MOD(X,2)=0, CAST(MOD(X,100)-50 AS TINYINT), CAST(-1000+X AS SMALLINT), CAST(-9000000000000000000 AS BIGINT)+X, CAST(X/7.0 AS REAL), CAST(X/7.0 AS DOUBLE), 'abc', X'00FF0102', DATE '2026-10-23', TIME '12:34:56.123456789', TIMESTAMP '2026-10-23 12:34:56.123456789', TIMESTAMP WITH TIME ZONE '2026-10-23 12:34:56.123456789+00:00:01', ARRAY[X,NULL,X+1], ROW(CAST(X AS INT), 'nested-' || X), CASE WHEN MOD(X,2)=0 THEN UUID '12345678-9abc-def0-fedc-ba9876543210' ELSE UUID 'fedcba98-7654-3210-1234-56789abcdef0' END FROM SYSTEM_RANGE(1,180)");
            statement.execute("CREATE INDEX TEST_TXT ON TEST(TXT DESC NULLS LAST)");
            statement.execute("CREATE INDEX TEST_UUID ON TEST(U)");
        }
    }

    private static void dumpSQL(String path) throws Exception {
        ValueDataType codec = new ValueDataType();
        try (java.sql.Connection connection = connection(path, true)) {
            try (JdbcResultSet rows = (JdbcResultSet)connection.createStatement().executeQuery("SELECT * FROM TEST ORDER BY ID")) {
                while (rows.next()) {
                    StringBuilder line = new StringBuilder(Integer.toString(rows.getInt(1)));
                    for (int i = 1; i <= rows.getMetaData().getColumnCount(); i++) {
                        WriteBuffer buffer = new WriteBuffer();
                        codec.write(buffer, rows.getInternal(i));
                        line.append('\t').append(hex(bytes(buffer)));
                    }
                    System.out.println(line);
                }
            }
        }
    }

    private static void pending(String path, boolean recover) {
        MVStore store = new MVStore.Builder().fileName(path).autoCommitDisabled().autoCompactFillRate(0).open();
        try {
            TransactionStore transactions = new TransactionStore(store, new MetaType<>(null, null), new ValueDataType(), 0);
            transactions.init();
            if (recover) {
                transactions.endLeftoverTransactions();
                Transaction transaction = transactions.begin();
                TransactionMap<Long, Value> map = transaction.openMap("pending", LongDataType.INSTANCE, new ValueDataType());
                if (map.sizeAsLong() != 2 || map.get(1L).getInt() != 10 || map.get(2L).getInt() != 11 || map.get(3L) != null) {
                    throw new IllegalStateException("Native versioned values broke transaction recovery");
                }
                transaction.commit();
                store.commit();
                store.close();
            } else {
                Transaction transaction = transactions.begin();
                TransactionMap<Long, Value> map = transaction.openMap("pending", LongDataType.INSTANCE, new ValueDataType());
                map.put(1L, ValueInteger.get(10));
                map.put(2L, ValueInteger.get(11));
                transaction.commit();
                store.commit();
                transaction = transactions.begin();
                map = transaction.openMap("pending", LongDataType.INSTANCE, new ValueDataType());
                map.put(1L, ValueInteger.get(20));
                map.remove(2L);
                map.put(3L, ValueVarchar.get("inserted"));
                store.commit();
            }
        } finally {
            store.closeImmediately();
        }
    }

    private static void pendingSQL(String path) throws Exception {
        createSQL(path);
        java.sql.Connection connection = connection(path, false);
        connection.setAutoCommit(false);
        java.sql.Statement statement = connection.createStatement();
        statement.execute("UPDATE TEST SET TXT='uncommitted', N=-100.25 WHERE ID=1");
        statement.execute("INSERT INTO TEST(ID, TXT, N) VALUES(1000, 'discarded', 99)");
        statement.execute("DELETE FROM TEST WHERE ID=180");
        org.h2.engine.SessionLocal session = (org.h2.engine.SessionLocal)((org.h2.jdbc.JdbcConnection)connection).getSession();
        MVStore store = session.getDatabase().getStore().getMvStore();
        store.commit();
        store.closeImmediately();
    }

    public static void main(String[] args) throws Exception {
        if (args[0].equals("vectors")) vectors();
        else if (args[0].equals("meta-vectors")) metaVectors();
        else if (args[0].equals("create-sql")) createSQL(args[1]);
        else if (args[0].equals("pending-sql")) pendingSQL(args[1]);
        else if (args[0].equals("dump-sql")) dumpSQL(args[1]);
        else if (args[0].equals("create-pending")) pending(args[1], false);
        else if (args[0].equals("recover-pending")) pending(args[1], true);
        else if (args[0].equals("check-index")) {
            try (java.sql.Connection connection = connection(args[1], true);
                    java.sql.ResultSet rows = connection.createStatement().executeQuery("SELECT COUNT(*) FROM TEST WHERE TXT='native 😀'")) {
                rows.next();
                if (rows.getInt(1) != 1) throw new IllegalStateException("Native string index mismatch");
            }
        }
        else if (args[0].equals("mutate-sql")) {
            try (java.sql.Connection connection = connection(args[1], false)) {
                java.sql.Statement statement = connection.createStatement();
                statement.execute("UPDATE TEST SET N=-99.25, TXT='java-after-ruby' WHERE ID=42");
                statement.execute("INSERT INTO TEST(ID, TXT, N) VALUES(1000, 'late', 123.0001)");
                statement.execute("DELETE FROM TEST WHERE ID=180");
            }
        }
        else throw new IllegalArgumentException(args[0]);
    }
}
