import java.io.ByteArrayInputStream;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.StringReader;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.security.MessageDigest;
import java.sql.DriverManager;
import java.util.HexFormat;
import java.util.Map;
import java.util.Queue;
import java.util.concurrent.atomic.AtomicLong;
import org.h2.engine.SessionLocal;
import org.h2.jdbc.JdbcConnection;
import org.h2.mvstore.MVStore;
import org.h2.mvstore.WriteBuffer;
import org.h2.mvstore.db.LobStorageMap;
import org.h2.mvstore.db.ValueDataType;
import org.h2.mvstore.type.DataType;
import org.h2.mvstore.type.LongDataType;
import org.h2.mvstore.type.ByteArrayDataType;
import org.h2.value.ValueLob;
import org.h2.value.lob.LobDataDatabase;

public class LobLifecycleOracle {
    private static final HexFormat HEX = HexFormat.of();

    private static Object field(Object target, String name) throws Exception {
        Field field = target.getClass().getDeclaredField(name);
        field.setAccessible(true);
        return field.get(target);
    }

    @SuppressWarnings("unchecked")
    private static Map<Object,Object> map(LobStorageMap storage, String name) throws Exception {
        return (Map<Object,Object>)field(storage,name);
    }

    @SuppressWarnings({"rawtypes","unchecked"})
    private static String encode(DataType type, Object value) {
        WriteBuffer buffer = new WriteBuffer();
        type.write(buffer,value);
        byte[] bytes = new byte[buffer.position()];
        buffer.getBuffer().flip().get(bytes);
        return HEX.formatHex(bytes);
    }

    private static String digest(byte[] bytes) throws Exception {
        return HEX.formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }

    private static void value(String label, ValueLob value) throws Exception {
        try (var input = value.getInputStream()) {
            System.out.println(label + "\t" + encode(new ValueDataType(),value) + "\t" + digest(input.readAllBytes()));
        }
    }

    private static void snapshot(LobStorageMap storage) throws Exception {
        var meta = map(storage,"lobMap");
        var temp = map(storage,"tempLobMap");
        var refs = map(storage,"refMap");
        for (var entry : meta.entrySet()) System.out.println("M\t" + entry.getKey() + "\t" + encode(LobStorageMap.BlobMeta.Type.INSTANCE,entry.getValue()));
        for (var entry : temp.entrySet()) System.out.println("T\t" + entry.getKey() + "\t" + HEX.formatHex((byte[])entry.getValue()));
        for (var entry : refs.entrySet()) System.out.println("R\t" + encode(LobStorageMap.BlobReference.Type.INSTANCE,entry.getKey()));
        System.out.println("N\t" + ((AtomicLong)field(storage,"nextLobId")).get() + "\t" + ((Queue<?>)field(storage,"pendingLobRemovals")).size());
    }

    private static void cleanup(LobStorageMap storage, long version) throws Exception {
        Method method = LobStorageMap.class.getDeclaredMethod("cleanup",long.class);
        method.setAccessible(true);
        method.invoke(storage,version);
    }

    private static byte[] bytes(int length, int seed) {
        byte[] data = new byte[length];
        for (int i = 0; i < length; i++) data[i] = (byte)(i * 31 + seed);
        return data;
    }

    private static String text(String hex) {
        ByteBuffer bytes = ByteBuffer.wrap(HEX.parseHex(hex));
        StringBuilder text = new StringBuilder();
        while (bytes.hasRemaining()) text.append(bytes.getChar());
        return text.toString();
    }

    private static void file(String action, String path, int compression) throws Exception {
        try (var connection = (JdbcConnection)DriverManager.getConnection("jdbc:h2:" + path + (compression == 0 ? "" : ";COMPRESS=TRUE"),"sa","")) {
            var database = ((SessionLocal)connection.getSession()).getDatabase();
            database.setMaxLengthInplaceLob(256);
            var storage = (LobStorageMap)database.getLobStorage();
            var raw = database.getStore().getMvStore();
            raw.setOldestVersionTracker(null);
            raw.setAutoCommitDelay(0);
            var values = database.getStore().getTransactionStore().openMap("lobValues",LongDataType.INSTANCE,ByteArrayDataType.INSTANCE);
            var codec = new ValueDataType(database,null);
            if (action.equals("create")) {
                var original = storage.createBlob(new ByteArrayInputStream(bytes(32768,7)),-1);
                var first = storage.copyLob(original,7);
                var second = storage.copyLob(first,8);
                values.put(1L,HEX.parseHex(encode(codec,first)));
                values.put(2L,HEX.parseHex(encode(codec,second)));
                var clob = storage.copyLob(storage.createClob(new StringReader("😀café".repeat(2000)),-1),7);
                values.put(3L,HEX.parseHex(encode(codec,clob)));
                values.put(4L,HEX.parseHex(encode(codec,storage.createBlob(new ByteArrayInputStream(new byte[] {1,2,3}),3))));
                values.put(5L,HEX.parseHex(encode(codec,storage.createClob(new StringReader("abc"),3))));
            } else if (action.equals("append")) {
                storage.removeLob((ValueLob)codec.read(ByteBuffer.wrap(values.remove(1L))));
                cleanup(storage,raw.getCurrentVersion() + 1);
                var clob = (ValueLob)codec.read(ByteBuffer.wrap(values.get(3L)));
                values.put(6L,HEX.parseHex(encode(codec,storage.copyLob(clob,8))));
                storage.removeAllForTable(7);
                values.remove(3L);
                var blob = storage.copyLob(storage.createBlob(new ByteArrayInputStream(bytes(400000,9)),-1),9);
                values.put(7L,HEX.parseHex(encode(codec,blob)));
            } else if (action.equals("dump")) {
                for (var entry : values.entrySet()) {
                    var lob = (ValueLob)codec.read(ByteBuffer.wrap(entry.getValue()));
                    value("V" + entry.getKey(),lob);
                }
                snapshot(storage);
            } else throw new IllegalArgumentException(action);
            storage.close();
        }
    }

    private static void probes() throws Exception {
        try (var connection = (JdbcConnection)DriverManager.getConnection("jdbc:h2:mem:lob_probes","sa","")) {
            var database = ((SessionLocal)connection.getSession()).getDatabase();
            database.setMaxLengthInplaceLob(256);
            var storage = (LobStorageMap)database.getLobStorage();
            var raw = database.getStore().getMvStore();
            raw.setOldestVersionTracker(null);
            raw.setAutoCommitDelay(0);
            var overflow = storage.createClob(new StringReader("abc"),1L << 62);
            System.out.println("overflow\t" + overflow.charLength());
            try { storage.getInputStream(999,7,0); }
            catch (Exception error) { System.out.println("missing\t" + error.getClass().getSimpleName()); }
            var value = storage.createBlob(new ByteArrayInputStream(bytes(600000,3)),-1);
            try (var reader = value.getInputStream()) {
                reader.read();
                storage.removeLob(value);
                cleanup(storage,raw.getCurrentVersion() + 1);
                try { reader.readAllBytes(); }
                catch (Exception error) { System.out.println("reader\t" + error.getClass().getSimpleName()); }
            }
            var first = storage.createBlob(new ByteArrayInputStream(new byte[] {1}),-1);
            var second = storage.createBlob(new ByteArrayInputStream(new byte[] {2}),-1);
            storage.removeLob(first);
            long version = (long)field(((Queue<?>)field(storage,"pendingLobRemovals")).peek(),"version");
            raw.commit();
            storage.removeLob(second);
            cleanup(storage,version);
            cleanup(storage,version + 1);
            System.out.println("queue\t" + map(storage,"tempLobMap").size());
            storage.close();
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length > 0) {
            if (args[0].equals("probes")) {
                probes();
                return;
            }
            file(args[0],args[1],args.length > 2 ? Integer.parseInt(args[2]) : 0);
            return;
        }
        try (var connection = (JdbcConnection)DriverManager.getConnection("jdbc:h2:mem:lifecycle","sa","");
                var input = new BufferedReader(new InputStreamReader(System.in))) {
            var database = ((SessionLocal)connection.getSession()).getDatabase();
            database.setMaxLengthInplaceLob(256);
            var storage = (LobStorageMap)database.getLobStorage();
            MVStore raw = database.getStore().getMvStore();
            raw.setOldestVersionTracker(null);
            raw.setAutoCommitDelay(0);
            String line;
            while ((line = input.readLine()) != null) {
                String[] fields = line.split("\t",-1);
                long max = Long.parseLong(fields[2]);
                ValueLob value;
                if (fields[0].equals("B")) {
                    value = storage.createBlob(new ByteArrayInputStream(bytes(Integer.parseInt(fields[1]),7)),max);
                } else {
                    value = storage.createClob(new StringReader(text(fields[1])),max);
                }
                value("V",value);
                if (value.getLobData() instanceof LobDataDatabase) {
                    ValueLob permanent = storage.copyLob(value,7);
                    ValueLob result = storage.copyLob(permanent,-3);
                    value("P",permanent);
                    value("Q",result);
                    snapshot(storage);
                    storage.removeLob(value);
                    storage.removeLob(permanent);
                    cleanup(storage,raw.getCurrentVersion() + 1);
                    value("S",result);
                    snapshot(storage);
                    storage.removeAllForTable(-3);
                }
                snapshot(storage);
                System.out.println("END");
            }
            storage.close();
        }
    }
}
