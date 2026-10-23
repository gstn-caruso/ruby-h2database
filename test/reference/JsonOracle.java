import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Types;
import org.h2.value.ValueJson;
import org.h2.value.ValueDecfloat;
import java.math.BigDecimal;

public class JsonOracle {
    private static void dump(PreparedStatement statement, Object... values) throws Exception {
        try {
            for (int i = 0; i < values.length; i++) {
                statement.setObject(i + 1, values[i]);
            }
            try (ResultSet result = statement.executeQuery()) {
                for (int i = 1; i <= result.getMetaData().getColumnCount(); i++) {
                    System.out.println("M\t" + result.getMetaData().getColumnLabel(i) + "\t"
                            + result.getMetaData().getColumnTypeName(i) + "\t"
                            + result.getMetaData().getPrecision(i) + "\t" + result.getMetaData().getScale(i));
                }
                while (result.next()) {
                    StringBuilder row = new StringBuilder("R");
                    for (int i = 1; i <= result.getMetaData().getColumnCount(); i++) {
                        String value = result.getString(i);
                        int type = result.getMetaData().getColumnType(i);
                        if (value != null && (type == Types.VARCHAR || type == Types.CHAR)) {
                            StringBuilder encoded = new StringBuilder("S");
                            for (char unit : value.toCharArray()) {
                                encoded.append(String.format("%04x", (int) unit));
                            }
                            value = encoded.toString();
                        }
                        row.append('\t').append(value);
                    }
                    System.out.println(row);
                }
            }
        } catch (SQLException error) {
            System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
        }
    }

    public static void main(String[] arguments) throws Exception {
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:json_values");
                Statement commands = connection.createStatement()) {
            if (arguments.length == 1 && arguments[0].equals("exponent-boundary")) {
                System.out.println("J\t" + Runtime.version());
                try (PreparedStatement statement = connection.prepareStatement("SELECT '1e2147483648' FORMAT JSON AS j")) {
                    dump(statement);
                } catch (SQLException error) {
                    System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
                }
                return;
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS JSON) AS casted,? FORMAT JSON AS parsed,? IS JSON WITH UNIQUE KEYS AS valid,(? FORMAT JSON)[?] AS item,? IS OF(JSON) AS istype")) {
                dump(statement, "x", "[1,null]", "{\"a\":1,\"a\":2}", "[1,null]", 2, ValueJson.NULL);
                dump(statement, "[2]".getBytes(StandardCharsets.UTF_16LE), "{}".getBytes("UTF-32BE"), "[]".getBytes(StandardCharsets.UTF_8), null, 1, null);
                dump(statement, null, null, null, null, null, "null");
                dump(statement, "null", "bad", "{}", "[]", 1, ValueJson.NULL);
                dump(statement, "null".getBytes(StandardCharsets.UTF_8), "1.00", 1, "[]", -1, ValueJson.get(1));
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT JSON_OBJECT(?:?,?:? ABSENT ON NULL WITH UNIQUE KEYS) AS o,JSON_ARRAY(?,? NULL ON NULL) AS a")) {
                dump(statement, "a", 1, "a", null, null, ValueJson.NULL);
                dump(statement, "a", 1, "a", 2, 1, 2);
                dump(statement, null, 1, "a", 2, 1, 2);
                dump(statement, "a", ValueJson.NULL, "b", "x", ValueJson.fromJson("[]"), "x");
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS JSON(4)) AS j")) {
                dump(statement, "null".getBytes(StandardCharsets.UTF_8));
                dump(statement, "true".getBytes(StandardCharsets.UTF_8));
                dump(statement, "é");
                dump(statement, "😀");
                dump(statement, new String(new char[] {0xd800}));
                dump(statement, (Object) null);
                dump(statement, new byte[] {(byte) 0xff});
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(CAST(? AS JSON) AS VARCHAR(3)) AS v,CAST(CAST(? AS JSON) AS CHAR(2)) AS c")) {
                dump(statement, "\"😀\"".getBytes(StandardCharsets.UTF_8), "\"😀\"".getBytes(StandardCharsets.UTF_8));
                dump(statement, "{}".getBytes(StandardCharsets.UTF_8), "{}".getBytes(StandardCharsets.UTF_8));
                dump(statement, null, null);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS JSON) AS j,CAST(? AS DECFLOAT(3)) AS d")) {
                dump(statement, ValueDecfloat.get(new BigDecimal("1.2300e100")), ValueDecfloat.get(new BigDecimal("9.999")));
                dump(statement, ValueDecfloat.POSITIVE_INFINITY, ValueDecfloat.ZERO);
                dump(statement, null, null);
            }
            commands.execute("CREATE TABLE source(v INT)");
            commands.execute("INSERT INTO source VALUES(1),(2)");
            try (PreparedStatement statement = connection.prepareStatement("CREATE TABLE saved(j JSON DEFAULT JSON_ARRAY(SELECT v FROM source WHERE v>? ORDER BY v))")) {
                statement.setInt(1, 1);
                statement.execute();
            }
            commands.execute("INSERT INTO saved DEFAULT VALUES");
            commands.execute("INSERT INTO source VALUES(3)");
            commands.execute("INSERT INTO saved DEFAULT VALUES");
            try (PreparedStatement statement = connection.prepareStatement("TABLE saved")) {
                dump(statement);
            }
        }
    }
}
