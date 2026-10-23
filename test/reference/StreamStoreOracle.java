import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.security.MessageDigest;
import java.sql.DriverManager;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.Map;
import java.util.TreeMap;
import org.h2.mvstore.MVStore;
import org.h2.mvstore.StreamStore;
import org.h2.mvstore.WriteBuffer;
import org.h2.mvstore.db.LobStorageMap.BlobMeta;
import org.h2.mvstore.db.LobStorageMap.BlobReference;
import org.h2.mvstore.db.NullValueDataType;
import org.h2.mvstore.tx.TransactionStore;
import org.h2.mvstore.type.ByteArrayDataType;
import org.h2.mvstore.type.LongDataType;
import org.h2.value.ValueNull;

public class StreamStoreOracle {
    private static final HexFormat HEX = HexFormat.of();

    private static byte[] data(int length, int seed) {
        byte[] bytes = new byte[length];
        for (int i = 0; i < length; i++) bytes[i] = (byte)(i * 31 + seed * 17 + (i >> 8));
        return bytes;
    }

    private static String digest(byte[] bytes) throws Exception {
        return HEX.formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }

    private static String encoded(Object value) {
        WriteBuffer buffer = new WriteBuffer();
        if (value instanceof BlobMeta) BlobMeta.Type.INSTANCE.write(buffer,(BlobMeta)value);
        else BlobReference.Type.INSTANCE.write(buffer,(BlobReference)value);
        byte[] bytes = new byte[buffer.position()];
        buffer.getBuffer().flip().get(bytes);
        return HEX.formatHex(bytes);
    }

    private static String snapshot(Map<Long,byte[]> map) throws Exception {
        StringBuilder text = new StringBuilder();
        for (var entry : new TreeMap<>(map).entrySet()) {
            text.append(entry.getKey()).append(':').append(entry.getValue().length).append(':').append(digest(entry.getValue())).append(';');
        }
        return text.toString();
    }

    private static void vector(String[] fields) throws Exception {
        int min = Integer.parseInt(fields[1]), max = Integer.parseInt(fields[2]);
        int length = Integer.parseInt(fields[4]), seed = Integer.parseInt(fields[5]), shortRead = Integer.parseInt(fields[6]);
        TreeMap<Long,byte[]> map = new TreeMap<>();
        for (int i = 0; i < Integer.parseInt(fields[7]); i++) map.put((long)i,new byte[] {(byte)i});
        StringBuilder writes = new StringBuilder();
        StreamStore store = new StreamStore(map,min,max,n -> writes.append(n).append(','));
        store.setNextKey(Long.parseLong(fields[3]));
        InputStream input = new ByteArrayInputStream(data(length,seed)) {
            @Override public synchronized int read(byte[] bytes, int offset, int count) {
                return super.read(bytes,offset,shortRead == 0 ? count : Math.min(count,shortRead));
            }
        };
        byte[] id = store.put(input);
        System.out.println("S\t" + HEX.formatHex(id) + "\t" + store.getNextKey() + "\t" + store.length(id) + "\t" + store.isInPlace(id)
                + "\t" + store.getMaxBlockKey(id) + "\t" + digest(store.get(id).readAllBytes()) + "\t" + writes + "\t" + snapshot(map));
        for (long skip : new long[] {0,1,max + 3L,length + 3L}) {
            InputStream reader = store.get(id);
            long moved = reader.skip(skip);
            byte[] first = new byte[3];
            int count = reader.read(first);
            byte[] rest = reader.readAllBytes();
            reader.close();
            System.out.println("R\t" + moved + "\t" + count + "\t" + (count < 0 ? "" : HEX.formatHex(Arrays.copyOf(first,count)))
                    + "\t" + digest(rest) + "\t" + reader.read());
        }
        store.remove(id);
        System.out.println("D\t" + snapshot(map));
    }

    private static void codecs(String[] fields) {
        byte[] id = HEX.parseHex(fields[1]);
        var meta = new BlobMeta(id,Integer.parseInt(fields[2]),Long.parseLong(fields[3]),Long.parseLong(fields[4]));
        var reference = new BlobReference(id,Long.parseLong(fields[3]));
        String m = encoded(meta), r = encoded(reference);
        var decodedMeta = BlobMeta.Type.INSTANCE.read(ByteBuffer.wrap(HEX.parseHex(m)));
        var decodedReference = BlobReference.Type.INSTANCE.read(ByteBuffer.wrap(HEX.parseHex(r)));
        System.out.println("M\t" + m + "\t" + r + "\t" + encoded(decodedMeta) + "\t" + encoded(decodedReference));
    }

    private static void bugs() throws Exception {
        StreamStore store = new StreamStore(new TreeMap<>(),10,20);
        store.setNextKey(123);
        byte[] id = store.put(new ByteArrayInputStream(data(200,0)));
        try { System.out.println(StreamStore.toString(id)); }
        catch (Exception error) { System.out.println("describe\t" + error.getClass().getSimpleName()); }
        byte[] combined = HEX.parseHex("0001aa0002bbcc0002ddee");
        InputStream reader = store.get(combined);
        reader.skip(2);
        System.out.println("inline\t" + reader.read() + "\t" + reader.read());
        TreeMap<Long,byte[]> map = new TreeMap<>();
        map.put(100L,new byte[] {1});
        map.put(1L,new byte[] {0,1,2});
        System.out.println("maximum\t" + new StreamStore(map).getMaxBlockKey(new byte[] {1,1,100,2,1,1}));
        map.clear();
        store = new StreamStore(map,10,20);
        try {
            store.put(new InputStream() {
                int calls;
                @Override public int read() { throw new UnsupportedOperationException(); }
                @Override public int read(byte[] bytes, int offset, int count) throws IOException {
                    if (++calls == 8) throw new IOException("broken");
                    Arrays.fill(bytes,offset,offset + count,(byte)1);
                    return count;
                }
            });
        } catch (IOException error) { System.out.println("cleanup\t" + map.size()); }
        map.clear();
        map.put(Long.MAX_VALUE,new byte[] {1});
        store = new StreamStore(map,1,8);
        store.setNextKey(Long.MAX_VALUE);
        store.put(new ByteArrayInputStream(new byte[] {2}));
        System.out.println("overwrite\t" + map.get(Long.MAX_VALUE)[0]);
    }

    private static void file(String action, String path, int compression) throws Exception {
        var builder = new MVStore.Builder().fileName(path).autoCommitDisabled().autoCompactFillRate(0).keysPerPage(8);
        if (compression == 1) builder.compress();
        if (compression == 2) builder.compressHigh();
        try (var raw = builder.open()) {
            var transactions = new TransactionStore(raw);
            transactions.init();
            var blocks = transactions.openMap("lobData",LongDataType.INSTANCE,ByteArrayDataType.INSTANCE);
            var metadata = transactions.openMap("lobMap",LongDataType.INSTANCE,BlobMeta.Type.INSTANCE);
            var references = transactions.openMap("lobRef",BlobReference.Type.INSTANCE,NullValueDataType.INSTANCE);
            var streams = new StreamStore(blocks,64,1024);
            if (!blocks.isEmpty()) streams.setNextKey(blocks.lastKey() + 1);
            if (action.equals("create")) {
                int index = 0;
                for (int length : new int[] {0,1,63,64,1024,10000,300000}) {
                    long lobId = ++index;
                    byte[] id = streams.put(new ByteArrayInputStream(data(length,index)));
                    metadata.put(lobId,new BlobMeta(id,index % 2 == 0 ? -3 : 7,length,-lobId));
                    references.put(new BlobReference(id,lobId),ValueNull.INSTANCE);
                }
            } else if (action.equals("append")) {
                for (long lobId : new long[] {2,5}) {
                    var meta = metadata.remove(lobId);
                    references.remove(new BlobReference(meta.streamStoreId,lobId));
                    streams.remove(meta.streamStoreId);
                }
                byte[] id = streams.put(new ByteArrayInputStream(data(12345,8)));
                metadata.put(8L,new BlobMeta(id,9,12345,Long.MIN_VALUE));
                references.put(new BlobReference(id,8),ValueNull.INSTANCE);
            } else if (action.equals("dump")) {
                for (var entry : metadata.entrySet()) {
                    byte[] id = entry.getValue().streamStoreId;
                    System.out.println("M\t" + entry.getKey() + "\t" + encoded(entry.getValue()) + "\t" + streams.length(id) + "\t" + digest(streams.get(id).readAllBytes()));
                }
                for (var entry : references.entrySet()) System.out.println("F\t" + encoded(entry.getKey()));
                System.out.println("B\t" + snapshot(blocks));
            } else throw new IllegalArgumentException(action);
            raw.commit();
        }
    }

    private static void sql(String path) throws Exception {
        try (var connection = DriverManager.getConnection("jdbc:h2:" + path,"sa",""); var statement = connection.createStatement()) {
            statement.execute("CREATE TABLE t(b BLOB,c CLOB)");
            byte[] blob = data(300000,7);
            String clob = "café 😀".repeat(10000);
            try (var insert = connection.prepareStatement("INSERT INTO t VALUES(?,?)")) {
                insert.setBinaryStream(1,new ByteArrayInputStream(blob));
                insert.setCharacterStream(2,new java.io.StringReader(clob));
                insert.executeUpdate();
            }
            System.out.println("B\t" + digest(blob));
            System.out.println("C\t" + digest(clob.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length > 0) {
            if (args[0].equals("bugs")) bugs();
            else if (args[0].equals("sql")) sql(args[1]);
            else file(args[0],args[1],args.length > 2 ? Integer.parseInt(args[2]) : 0);
            return;
        }
        try (BufferedReader input = new BufferedReader(new InputStreamReader(System.in))) {
            String line;
            while ((line = input.readLine()) != null) {
                String[] fields = line.split("\t",-1);
                if (fields[0].equals("S")) vector(fields);
                else if (fields[0].equals("M")) codecs(fields);
                else if (fields[0].equals("C")) {
                    BlobReference left = fields[1].equals("-") ? null : new BlobReference(HEX.parseHex(fields[1]),Long.parseLong(fields[2]));
                    BlobReference right = fields[3].equals("-") ? null : new BlobReference(HEX.parseHex(fields[3]),Long.parseLong(fields[4]));
                    System.out.println("C\t" + Integer.signum(BlobReference.Type.INSTANCE.compare(left,right)));
                }
                else throw new IllegalArgumentException(fields[0]);
                System.out.println("END");
            }
        }
    }
}
