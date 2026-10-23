import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.OffsetTime;
import java.time.ZoneOffset;

public class ArrayParametersOracle {
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
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:array_parameters");
                Statement commands = connection.createStatement()) {
            for (String sql : new String[] {"SELECT ARRAY[?]", "SELECT ARRAY[?,NULL]", "SELECT ARRAY[CAST(? AS INT)]",
                    "SELECT ?[1]", "SELECT TRIM_ARRAY(?,0)", "SELECT ARRAY_SLICE(?,1,2)",
                    "SELECT ARRAY_LENGTH(?)", "SELECT ARRAY_MAX_CARDINALITY(?)"}) {
                try (PreparedStatement statement = connection.prepareStatement(sql)) {
                    System.out.println("P\t" + sql + "\tOK");
                } catch (SQLException error) {
                    System.out.println("P\t" + sql + "\t" + error.getErrorCode() + "\t" + error.getSQLState());
                }
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT CARDINALITY(CAST(? AS INT ARRAY)) AS n")) {
                dump(statement, (Object) new Object[65536]);
                dump(statement, (Object) new Object[65537]);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS INTEGER ARRAY[2]) AS a,"
                    + "ARRAY_GET(CAST(? AS INTEGER ARRAY),?) AS e")) {
                dump(statement, new Object[] {1, null, 3}, new Object[] {3, 4}, 1);
                dump(statement, null, null, 1);
                dump(statement, new Object[] {}, new Object[] {3, 4}, 0);
                dump(statement, new Object[] {1}, new Object[] {3, 4}, 3);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT ? AS a")) {
                dump(statement, (Object) new Object[] {});
                dump(statement, (Object) new Object[] {1, null, 3});
                dump(statement, (Object) new Object[] {"a", "bbb"});
                dump(statement, (Object) new Object[] {new Object[] {1, 2}, new Object[] {3}});
                dump(statement, (Object) new Object[] {OffsetTime.of(12, 0, 0, 1, ZoneOffset.ofHours(3)), null});
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT ARRAY_SLICE(CAST(? AS INT ARRAY),?,?) AS a")) {
                dump(statement, new Object[] {1, 2, 3}, 2, 3);
                dump(statement, null, "bad", "bad");
                dump(statement, new Object[] {1}, "bad", null);
                dump(statement, new Object[] {1, 2}, 3, 2);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT ARRAY[?,CAST(? AS BIGINT)] AS a,"
                    + "ARRAY_LENGTH(CAST(? AS INT ARRAY)) AS n")) {
                dump(statement, 1, 2, new Object[] {1, 2, 3});
                dump(statement, null, null, null);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT ARRAY(SELECT x FROM SYSTEM_RANGE(1,3) WHERE x<=?) AS a")) {
                dump(statement, 2);
                statement.setObject(1, null);
                try {
                    statement.executeQuery();
                    throw new AssertionError("Expected the RangeIndex NULL-bound failure");
                } catch (SQLException error) {
                    if (error.getErrorCode() != 50000) {
                        throw error;
                    }
                    System.out.println("D\tRangeIndex NULL bound\t50000");
                }
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT ARRAY(SELECT x FROM (VALUES 1,2,3) t(x) WHERE x<=?) AS a")) {
                dump(statement, 2);
                dump(statement, (Object) null);
            }
            try (PreparedStatement statement = connection.prepareStatement("CREATE TABLE saved(a INT ARRAY DEFAULT CAST(? AS INT ARRAY))")) {
                statement.setObject(1, new Object[] {1, null, 3});
                statement.execute();
            }
            commands.execute("INSERT INTO saved DEFAULT VALUES");
            try (PreparedStatement statement = connection.prepareStatement("TABLE saved")) {
                dump(statement);
            }
        }
    }
}
