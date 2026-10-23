import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.Base64;
import java.util.HexFormat;
import org.h2.engine.SessionLocal;
import org.h2.jdbc.JdbcConnection;
import org.h2.jdbc.JdbcResultSet;
import org.h2.value.Value;
import org.h2.value.ValueCollectionBase;
import org.h2.value.ValueBlob;
import org.h2.value.ValueClob;

public class LobSqlOracle {
    private static final HexFormat HEX = HexFormat.of();

    private static String units(String text) {
        byte[] bytes = new byte[text.length() * 2];
        for (int i = 0; i < text.length(); i++) {
            bytes[i * 2] = (byte)(text.charAt(i) >>> 8);
            bytes[i * 2 + 1] = (byte)text.charAt(i);
        }
        return HEX.formatHex(bytes);
    }

    private static String digest(byte[] bytes) throws Exception {
        return HEX.formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }

    private static String value(Value value) throws Exception {
        switch (value.getValueType()) {
        case Value.NULL: return "N";
        case Value.BLOB: {
            byte[] bytes = value.getBytesNoCopy();
            return "B" + bytes.length + ":" + digest(bytes);
        }
        case Value.CLOB: {
            String text = value.getString();
            byte[] bytes = value.getBytesNoCopy();
            return "C" + text.length() + ":" + digest(HEX.parseHex(units(text))) + ":" + bytes.length + ":" + digest(bytes);
        }
        case Value.BINARY:
        case Value.VARBINARY: return "Y" + HEX.formatHex(value.getBytesNoCopy());
        case Value.CHAR:
        case Value.VARCHAR: return "S" + units(value.getString());
        case Value.ARRAY:
        case Value.ROW: {
            StringBuilder text = new StringBuilder(value.getValueType() == Value.ARRAY ? "A[" : "R[");
            for (Value item : ((ValueCollectionBase)value).getList()) text.append(value(item)).append(';');
            return text.append(']').toString();
        }
        default: return "V" + units(value.getString());
        }
    }

    private static void dump(ResultSet result) throws Exception {
        var metadata = result.getMetaData();
        for (int i = 1; i <= metadata.getColumnCount(); i++) {
            System.out.println("M\t" + units(metadata.getColumnLabel(i)) + "\t" + units(metadata.getColumnTypeName(i))
                    + "\t" + metadata.getPrecision(i) + "\t" + metadata.getScale(i));
        }
        while (result.next()) {
            StringBuilder row = new StringBuilder("R");
            for (int i = 1; i <= metadata.getColumnCount(); i++) row.append('\t').append(value(((JdbcResultSet)result).getInternal(i)));
            System.out.println(row);
        }
    }

    private static void prepared(JdbcConnection connection) throws Exception {
        Object[] values = {null,true,1,new java.math.BigDecimal("1.25"),"abc","😀x",new byte[] {0,-1},
                ValueBlob.createSmall(new byte[] {0,-1}),ValueBlob.createSmall("😀".getBytes(StandardCharsets.UTF_8)),
                ValueClob.createSmall("abc"),ValueClob.createSmall("😀x"),new Object[] {1,2}};
        for (String sql : new String[] {"SELECT ? AS v","SELECT CAST(? AS BLOB) AS v","SELECT CAST(? AS CLOB) AS v",
                "SELECT CAST(? AS BLOB(3)) AS v","SELECT CAST(? AS CLOB(3)) AS v",
                "SELECT CHAR_LENGTH(CAST(? AS BLOB)) AS l,OCTET_LENGTH(CAST(? AS CLOB)) AS o",
                "SELECT ? FORMAT JSON AS v","SELECT ARRAY[CAST(? AS BLOB)] AS a"}) {
            try (var statement = connection.prepareStatement(sql)) {
                for (Object parameter : values) {
                    try {
                        for (int i = 1; i <= statement.getParameterMetaData().getParameterCount(); i++) statement.setObject(i,parameter);
                        try (var result = statement.executeQuery()) { dump(result); }
                    } catch (SQLException error) {
                        System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
                    }
                    System.out.println("END");
                }
            }
        }
        for (String sql : new String[] {"SELECT CAST(? AS BLOB(0))","SELECT CAST(? AS CLOB(8192P))",
                "SELECT CAST(? AS CLOB(1K OCTETS))","SELECT CAST(? AS BLOB(1K OCTETS))"}) {
            try (var statement = connection.prepareStatement(sql)) { System.out.println("P\tprepared"); }
            catch (SQLException error) { System.out.println("P\t" + error.getErrorCode() + "\t" + error.getSQLState()); }
            System.out.println("END");
        }
    }

    public static void main(String[] args) throws Exception {
        boolean prepared = args.length > 0 && args[0].equals("prepared");
        boolean empty = args.length > 0 && args[0].equals("empty");
        String url = empty ? args[1] : args.length == 0 || prepared ? "jdbc:h2:mem:lob_sql" : args[0];
        try (var connection = (JdbcConnection)DriverManager.getConnection(url,"sa","");
                var input = new BufferedReader(new InputStreamReader(System.in,StandardCharsets.UTF_8))) {
            ((SessionLocal)connection.getSession()).getDatabase().setMaxLengthInplaceLob(256);
            if (prepared) {
                prepared(connection);
                return;
            }
            if (empty) {
                try (var statement = connection.prepareStatement("CREATE TABLE e AS SELECT ? AS b,? AS c")) {
                    statement.setObject(1,ValueBlob.createSmall(new byte[0]));
                    statement.setObject(2,ValueClob.createSmall(""));
                    statement.execute();
                }
                try (var statement = connection.createStatement(); var result = statement.executeQuery("TABLE e")) { dump(result); }
                System.out.println("END");
                return;
            }
            String line;
            while ((line = input.readLine()) != null) {
                String sql = new String(Base64.getDecoder().decode(line),StandardCharsets.UTF_8);
                try (var statement = connection.createStatement()) {
                    if (statement.execute(sql)) {
                        try (var result = statement.getResultSet()) { dump(result); }
                    } else System.out.println("U\t" + statement.getUpdateCount());
                } catch (SQLException error) {
                    System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
                }
                System.out.println("END");
            }
        }
    }
}
