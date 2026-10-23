import java.nio.ByteBuffer;
import java.util.Map;
import org.h2.mvstore.MVStore;
import org.h2.mvstore.MVMap;
import org.h2.mvstore.MVStoreException;
import org.h2.mvstore.WriteBuffer;
import org.h2.mvstore.tx.Transaction;
import org.h2.mvstore.tx.TransactionMap;
import org.h2.mvstore.tx.TransactionStore;
import org.h2.mvstore.tx.VersionedValueType;
import org.h2.value.VersionedValue;
import org.h2.mvstore.type.ObjectDataType;
import org.h2.mvstore.type.StringDataType;

public class TransactionOracle {
    private static MVStore open(String path) {
        return new MVStore.Builder().fileName(path).autoCommitDisabled().autoCompactFillRate(0).open();
    }

    private static TransactionStore transactions(MVStore store) {
        TransactionStore result = new TransactionStore(store);
        result.init();
        result.endLeftoverTransactions();
        return result;
    }

    private static TransactionMap<String, String> data(Transaction tx) {
        return tx.openMap("data", StringDataType.INSTANCE, StringDataType.INSTANCE);
    }

    private static void line(String name, Object value) {
        System.out.println(name + "\t" + (value == null ? "-" : value));
    }

    private static void trace(String path) {
        try (MVStore store = open(path)) {
            TransactionStore transactions = transactions(store);
            Transaction seed = transactions.begin();
            data(seed).put("a", "zero");
            seed.commit();
            Transaction first = transactions.begin(), second = transactions.begin();
            TransactionMap<String, String> a = data(first), b = data(second);
            line("put", a.put("a", "one"));
            line("own", a.get("a"));
            line("other", b.get("a"));
            a.put("new", "fresh");
            line("hidden", b.get("new"));
            line("size", b.sizeAsLong());
            try { b.put("a", "conflict"); line("conflict", "missing"); }
            catch (MVStoreException error) { line("conflict", error.getErrorCode()); }
            line("try", b.tryPut("a", "conflict"));
            b.put("b", "two");
            long savepoint = first.setSavepoint();
            a.put("a", "second");
            a.remove("a");
            a.put("transient", "discarded");
            first.rollbackToSavepoint(savepoint);
            line("restored", a.get("a"));
            line("discarded", a.get("transient"));
            line("if-absent", a.putIfAbsent("a", "ignored"));
            line("lock", a.lock("a"));
            line("missing-lock", a.lock("absent"));
            first.commit();
            line("visible", b.get("a"));
            line("insert-visible", b.get("new"));
            second.commit();
            Transaction finalTx = transactions.begin();
            line("final-size", data(finalTx).sizeAsLong());
            finalTx.commit();
            store.commit();
        }
    }

    private static String hex(String value) {
        ByteBuffer bytes = ByteBuffer.allocate(value.length() * 2);
        for (int i = 0; i < value.length(); i++) bytes.putChar(value.charAt(i));
        return java.util.HexFormat.of().formatHex(bytes.array());
    }

    private static void dump(String path) {
        try (MVStore store = open(path)) {
            TransactionStore transactions = transactions(store);
            Transaction tx = transactions.begin();
            for (Map.Entry<String, String> entry : data(tx).entrySet()) {
                System.out.println(hex(entry.getKey()) + "\t" + hex(entry.getValue()));
            }
            tx.commit();
            store.commit();
        }
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private static void create(String path, String mode) throws Exception {
        MVStore store = open(path);
        try {
            TransactionStore transactions = transactions(store);
            Transaction seed = transactions.begin();
            data(seed).put("a", "zero");
            data(seed).put("obsolete", "old");
            seed.commit();
            Transaction tx = transactions.begin();
            TransactionMap<String, String> map = data(tx);
            map.put("a", "first update");
            map.put("a", "decided 😀");
            map.remove("obsolete");
            map.put("new", "inserted");
            if (mode.equals("prepared")) {
                tx.setName("payment 😀");
                tx.prepare();
            } else if (mode.equals("marked")) {
                Class<?> type = Class.forName("org.h2.mvstore.tx.Record");
                java.lang.reflect.Constructor<?> constructor = type.getDeclaredConstructor(int.class);
                constructor.setAccessible(true);
                MVMap log = store.openMap("undoLog." + tx.getId());
                log.put(((long)tx.getId() << 40) | ((1L << 40) - 1), constructor.newInstance(-1));
            }
            store.commit();
        } finally {
            store.closeImmediately();
        }
    }

    private static void resolve(String path, boolean commit) {
        try (MVStore store = open(path)) {
            TransactionStore transactions = transactions(store);
            int count = 0;
            for (Transaction tx : transactions.getOpenTransactions()) {
                if (tx.getStatus() == Transaction.STATUS_PREPARED) {
                    if (!"payment 😀".equals(tx.getName())) throw new IllegalStateException("Prepared name mismatch");
                    if (commit) tx.commit(); else tx.rollback();
                    count++;
                }
            }
            if (count != 1) throw new IllegalStateException("Expected one prepared transaction");
            store.commit();
        }
    }

    private static void markedSnapshot(String path) {
        try (MVStore store = new MVStore.Builder().fileName(path).readOnly().open()) {
            TransactionStore transactions = new TransactionStore(store);
            transactions.init();
            if (transactions.getOpenTransactions().size() != 1 ||
                    transactions.getOpenTransactions().get(0).getStatus() != Transaction.STATUS_COMMITTED) {
                throw new IllegalStateException("Java did not recognize the persisted commit decision");
            }
            MVMap<String, VersionedValue<String>> map = store.openMap("data",
                    new MVMap.Builder<String, VersionedValue<String>>().keyType(StringDataType.INSTANCE)
                            .valueType(new VersionedValueType<String, Object>(StringDataType.INSTANCE)));
            for (Map.Entry<String, VersionedValue<String>> entry : map.entrySet()) {
                if (entry.getValue().getCurrentValue() != null) {
                    System.out.println(hex(entry.getKey()) + "\t" + hex(entry.getValue().getCurrentValue()));
                }
            }
        }
    }

    private static void objectVectors() {
        Object[] values = {null, false, true, Integer.MIN_VALUE, -2097152, -2097151, -1, 0, 15, 16,
                2097151, 2097152, Integer.MAX_VALUE, "", "café 😀", "x".repeat(15), "x".repeat(16),
                new Object[] {2, "payment 😀"}, new Object[] {1, null}, new Object[] {new Object[] {true, 99}}};
        ObjectDataType codec = new ObjectDataType();
        for (int index = 0; index < values.length; index++) {
            WriteBuffer buffer = new WriteBuffer();
            codec.write(buffer, values[index]);
            ByteBuffer source = buffer.getBuffer();
            byte[] bytes = new byte[source.position()];
            source.rewind().get(bytes);
            System.out.println(index + "\t" + java.util.HexFormat.of().formatHex(bytes));
        }
    }

    public static void main(String[] args) throws Exception {
        switch (args[0]) {
        case "trace": trace(args[1]); break;
        case "dump": dump(args[1]); break;
        case "create": create(args[1], args[2]); break;
        case "commit-prepared": resolve(args[1], true); break;
        case "rollback-prepared": resolve(args[1], false); break;
        case "object-vectors": objectVectors(); break;
        case "marked-snapshot": markedSnapshot(args[1]); break;
        default: throw new IllegalArgumentException(args[0]);
        }
    }
}
