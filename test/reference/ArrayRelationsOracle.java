import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

public class ArrayRelationsOracle {
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
                        row.append('\t').append(result.getString(i));
                    }
                    System.out.println(row);
                }
            }
        } catch (SQLException error) {
            System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
        }
    }

    public static void main(String[] arguments) throws Exception {
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:array_relations");
                Statement commands = connection.createStatement()) {
            try (PreparedStatement statement = connection.prepareStatement("SELECT ARRAY_AGG(CAST(? AS NUMERIC(5,2))+v ORDER BY k DESC) FILTER(WHERE v>?) AS a FROM (VALUES (0,1),(1,2),(2,3),(3,4)) t(v,k)")) {
                dump(statement, new BigDecimal("1.25"), 0);
                dump(statement, null, 0);
                dump(statement, new BigDecimal("-1.25"), 2);
                dump(statement, new BigDecimal("1.25"), null);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT * FROM UNNEST(?,CAST(? AS INT ARRAY)) WITH ORDINALITY")) {
                dump(statement, new Object[] {1, 2}, new Object[] {3});
                dump(statement, null, new Object[] {});
                dump(statement, new Object[] {"a", "b"}, new Object[] {3, 4, 5});
                dump(statement, "scalar", new Object[] {3, 4});
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT ARRAY_AGG(c1 ORDER BY c1) AS a FROM UNNEST(?)")) {
                dump(statement, (Object) new Object[] {2, 1, 2});
                dump(statement, (Object) new Object[] {});
                dump(statement, (Object) null);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT * FROM UNNEST(CAST(? AS NUMERIC(6,3) ARRAY)) WITH ORDINALITY")) {
                dump(statement, (Object) new Object[] {new BigDecimal("1.250"), null, new BigDecimal("2.125")});
                dump(statement, (Object) null);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT COUNT(*) FILTER(WHERE v>?) AS n,SUM(v) FILTER(WHERE v>?) AS s FROM (VALUES 0,1,2,3) t(v)")) {
                dump(statement, 1, 1);
                dump(statement, null, null);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT CARDINALITY(ARRAY_AGG(x)) AS n FROM SYSTEM_RANGE(1,CAST(? AS INT))")) {
                dump(statement, 0);
                dump(statement, 65536);
                dump(statement, 65537);
            }
            commands.execute("CREATE TABLE source(v INT)");
            commands.execute("INSERT INTO source VALUES(1),(2)");
            try (PreparedStatement statement = connection.prepareStatement("CREATE TABLE saved(a INT ARRAY DEFAULT (SELECT ARRAY_AGG(v ORDER BY v DESC) FILTER(WHERE v>?) FROM source))")) {
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
