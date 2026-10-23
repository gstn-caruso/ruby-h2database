import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Base64;
import org.h2.value.ExtTypeInfoRow;
import org.h2.value.TypeInfo;
import org.h2.value.Value;
import org.h2.value.ValueInteger;
import org.h2.value.ValueNull;
import org.h2.value.ValueRow;
import org.h2.value.ValueVarchar;

public class RowOracle {
    private static String units(String value) {
        if (value == null) return "null";
        StringBuilder text = new StringBuilder();
        for (int i = 0; i < value.length(); i++) text.append(String.format("%04x", (int)value.charAt(i)));
        return text.toString();
    }

    private static void dump(ResultSet result) throws Exception {
        var metadata = result.getMetaData();
        for (int i = 1; i <= metadata.getColumnCount(); i++) {
            System.out.println("M\t" + units(metadata.getColumnLabel(i)) + "\t" + units(metadata.getColumnTypeName(i))
                    + "\t" + metadata.getPrecision(i) + "\t" + metadata.getScale(i));
        }
        while (result.next()) {
            StringBuilder row = new StringBuilder("R");
            for (int i = 1; i <= metadata.getColumnCount(); i++) row.append('\t').append(units(result.getString(i)));
            System.out.println(row);
        }
    }

    private static void execute(Connection connection, String sql) throws Exception {
        try (Statement statement = connection.createStatement()) {
            if (statement.execute(sql)) {
                try (ResultSet result = statement.getResultSet()) { dump(result); }
            } else System.out.println("U\t" + statement.getUpdateCount());
        } catch (SQLException error) {
            System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
        }
    }

    private static void bound(PreparedStatement statement, Object... parameters) throws Exception {
        try {
            for (int i = 0; i < parameters.length; i++) statement.setObject(i + 1,parameters[i]);
            try (ResultSet result = statement.executeQuery()) { dump(result); }
        } catch (SQLException error) {
            System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
        }
    }

    private static void prepared(Connection connection) throws Exception {
        Object[] values = {null,1,"text",ValueRow.get(new Value[] {ValueInteger.get(1)}),
                ValueRow.get(new Value[] {ValueInteger.get(1),ValueInteger.get(2)}),
                ValueRow.get(new Value[] {ValueNull.INSTANCE,ValueInteger.get(2)}),
                ValueRow.get(new Value[] {ValueVarchar.get("1"),ValueVarchar.get("2")}),
                ValueRow.get(new Value[] {ValueVarchar.get("bad"),ValueVarchar.get("2")})};
        for (String sql : new String[] {"SELECT CAST(? AS ROW(a INT,b INT)) AS r",
                "SELECT (CAST(? AS ROW(a INT,b INT))).a AS a", "SELECT (CAST(? AS ROW(a INT,b INT))).b AS b"}) {
            try (PreparedStatement statement = connection.prepareStatement(sql)) {
                for (Object value : values) bound(statement,value);
            }
        }
        java.util.LinkedHashMap<String,TypeInfo> fields = new java.util.LinkedHashMap<>();
        fields.put("ID",TypeInfo.TYPE_INTEGER);
        fields.put("LABEL",TypeInfo.TYPE_VARCHAR);
        var ext = new ExtTypeInfoRow(fields);
        var typed = ValueRow.get(ext,new Value[] {ValueInteger.get(1),ValueVarchar.get("one")});
        for (String sql : new String[] {"SELECT CAST(? AS ROW(id INT,label VARCHAR)) AS r",
                "SELECT (CAST(? AS ROW(id INT,label VARCHAR))).label AS label"}) {
            try (PreparedStatement statement = connection.prepareStatement(sql)) {
                for (Object value : new Object[] {null,typed,ValueRow.get(new Value[] {ValueInteger.get(2),ValueVarchar.get("two")})}) bound(statement,value);
            }
        }
        for (String sql : new String[] {"SELECT (?).a", "SELECT (ROW(1)).missing WHERE FALSE", "SELECT (1).a WHERE FALSE",
                "SELECT CAST(? AS ROW(a INT,A INT))", "SELECT (CAST(? AS ROW(a INT))).a"}) {
            try (PreparedStatement statement = connection.prepareStatement(sql)) { System.out.println("P\tprepared"); }
            catch (SQLException error) { System.out.println("P\t" + error.getErrorCode() + "\t" + error.getSQLState()); }
        }
    }

    private static void limits(Connection connection) throws Exception {
        for (int count : new int[] {16384,16385}) {
            String fields = java.util.stream.IntStream.range(0,count).mapToObj(i -> "c" + i + " INT").collect(java.util.stream.Collectors.joining(","));
            String values = java.util.stream.IntStream.range(0,count).mapToObj(i -> "1").collect(java.util.stream.Collectors.joining(","));
            for (String sql : new String[] {"SELECT CAST(NULL AS ROW(" + fields + "))", "SELECT ROW(" + values + ")"}) {
                try (PreparedStatement statement = connection.prepareStatement(sql)) {
                    System.out.println("L\t" + count + "\tprepared");
                } catch (SQLException error) { System.out.println("L\t" + count + "\t" + error.getErrorCode()); }
            }
        }
    }

    public static void main(String[] args) throws Exception {
        boolean file = args.length > 0 && args[0].startsWith("jdbc:");
        try (Connection connection = DriverManager.getConnection(file ? args[0] : "jdbc:h2:mem:rows","sa","");
                BufferedReader input = new BufferedReader(new InputStreamReader(System.in,StandardCharsets.UTF_8))) {
            if (args.length > 0 && !file) {
                if (args[0].equals("prepared")) prepared(connection);
                else if (args[0].equals("limits")) limits(connection);
                else throw new IllegalArgumentException(args[0]);
                return;
            }
            String line;
            while ((line = input.readLine()) != null) {
                execute(connection,new String(Base64.getDecoder().decode(line),StandardCharsets.UTF_8));
                System.out.println("END");
            }
        }
    }
}
