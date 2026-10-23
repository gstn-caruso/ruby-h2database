import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.LocalTime;

public class QuantifiedOracle {
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
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:quantified");
                Statement commands = connection.createStatement()) {
            try (PreparedStatement statement = connection.prepareStatement("SELECT ?=ANY(?),? IS NOT DISTINCT FROM ALL(?),?>ALL(VALUES (?),(?))")) {
                dump(statement, 2, new Object[] {1, 2}, null, new Object[] {1, null}, 3, 1, 2);
                dump(statement, null, new Object[] {}, null, new Object[] {null}, 3, 1, null);
                dump(statement, 1, 1, null, null, 0, 1, 2);
                dump(statement, 2, new Object[] {"1", "bad"}, 1, new Object[] {1}, 3, 1, 2);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT ?=ANY(CAST(? AS NUMERIC(5,2) ARRAY)) AS a,?=ALL(SELECT * FROM UNNEST(?)) AS q")) {
                dump(statement, new BigDecimal("1.25"), new Object[] {new BigDecimal("1.25"), null}, 1, new Object[] {1, 2});
                dump(statement, null, new Object[] {}, 1, new Object[] {});
                dump(statement, 2, new Object[] {new BigDecimal("1.25"), null}, 1, new Object[] {1, 1});
                dump(statement, 1, null, null, new Object[] {null});
                dump(statement, 1, new Object[] {"bad"}, 1, new Object[] {});
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS TIME(9))=ANY(ARRAY[CAST(CURRENT_DATE AS TIMESTAMP)+TIME '12:00:00']) AS a")) {
                dump(statement, LocalTime.NOON);
                dump(statement, LocalTime.MIDNIGHT);
                dump(statement, LocalTime.of(12, 0, 0, 1));
                dump(statement, (Object) null);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT CASE ? WHEN =ANY(?) THEN 1 WHEN IS NOT DISTINCT FROM ALL(?) THEN 2 ELSE 3 END AS c")) {
                dump(statement, 1, new Object[] {1, 2}, new Object[] {1});
                dump(statement, null, new Object[] {1, null}, new Object[] {null});
                dump(statement, 2, new Object[] {}, new Object[] {2});
                dump(statement, 2, null, new Object[] {1});
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT ?>ANY(SELECT c1 FROM (VALUES 2,1) ORDER BY c1 DESC LIMIT ?) AS q")) {
                dump(statement, 2, 1);
                dump(statement, 2, 2);
            }
            commands.execute("CREATE TABLE source(v INT)");
            commands.execute("INSERT INTO source VALUES(1),(2)");
            try (PreparedStatement statement = connection.prepareStatement("CREATE TABLE saved(q BOOLEAN DEFAULT ?>ALL(SELECT v FROM source))")) {
                statement.setInt(1, 3);
                statement.execute();
            }
            commands.execute("INSERT INTO saved DEFAULT VALUES");
            commands.execute("INSERT INTO source VALUES(4)");
            commands.execute("INSERT INTO saved DEFAULT VALUES");
            try (PreparedStatement statement = connection.prepareStatement("TABLE saved")) {
                dump(statement);
            }
            commands.execute("SET TIME ZONE '+18'");
            String date;
            try (ResultSet result = commands.executeQuery("SELECT CURRENT_DATE")) {
                result.next();
                date = result.getString(1);
            }
            String array = "ARRAY[TIMESTAMP '" + date + " 12:00:00']";
            try (PreparedStatement statement = connection.prepareStatement("CREATE TABLE clock(f BOOLEAN DEFAULT TIME '12:00:00'=ANY(" + array
                    + "),d BOOLEAN DEFAULT ?=ANY(" + array + "),c INT DEFAULT CASE TIME '12:00:00' WHEN =ANY(" + array + ") THEN 1 ELSE 2 END)")) {
                statement.setObject(1, LocalTime.NOON);
                statement.execute();
            }
            commands.execute("INSERT INTO clock DEFAULT VALUES");
            commands.execute("SET TIME ZONE '-18'");
            commands.execute("INSERT INTO clock DEFAULT VALUES");
            try (PreparedStatement statement = connection.prepareStatement("TABLE clock")) {
                dump(statement);
            }
        }
    }
}
