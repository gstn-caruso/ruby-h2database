import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import org.h2.value.ValueDecfloat;

public class DecfloatOracle {
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
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:decfloat_values");
                Statement commands = connection.createStatement()) {
            try (PreparedStatement statement = connection.prepareStatement("SELECT CAST('1e100' AS DECFLOAT(12)),CAST(? AS DECFLOAT(12)),CAST(1 AS DECFLOAT(2))/CAST(6 AS DECFLOAT(2)) AS d")) {
                dump(statement, "1e100");
                dump(statement, (Object) null);
            }
            Object[][] pairs = {{"1.25", "0.3"}, {"1e100", "-3e-100"}, {"-5", "2"}, {"1", "0"},
                    {"Infinity", "-Infinity"}, {"NaN", "0"}, {null, "0"}, {"bad", "1"},
                    {ValueDecfloat.get(new BigDecimal("9.999")), ValueDecfloat.ONE}, {new byte[] {49}, "1"}};
            for (String operator : new String[] {"+", "-", "*", "/", "%"}) {
                try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS DECFLOAT(5))" + operator + "CAST(? AS DECFLOAT(3)) AS v")) {
                    for (Object[] pair : pairs) {
                        dump(statement, pair);
                    }
                }
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT ABS(CAST(? AS DECFLOAT(8))) AS a,SIGN(CAST(? AS DECFLOAT(8))) AS s")) {
                for (Object value : new Object[] {"-1e100", "0", "Infinity", "-Infinity", "NaN", null}) {
                    dump(statement, value, value);
                }
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS DECFLOAT(5))+CAST(? AS NUMERIC(10,2)) AS a,MOD(CAST(? AS DECFLOAT(5)),CAST(? AS DECFLOAT(3))) AS m")) {
                dump(statement, "1.25", "2.50", "5.25", "2");
                dump(statement, null, "2.50", "Infinity", "2");
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT MOD(CAST(1.2 AS DECFLOAT(5)),CAST(2 AS NUMERIC(10,2))) AS c,MOD(CAST(? AS DECFLOAT(5)),CAST(2 AS NUMERIC(10,2))) AS p")) {
                dump(statement, "1.2");
                dump(statement, "0");
            }
            commands.execute("CREATE TABLE t(v DECFLOAT(5),g INT)");
            commands.execute("INSERT INTO t VALUES(1.25,1),(2.5,1),(1.25,2),(NULL,2)");
            try (PreparedStatement statement = connection.prepareStatement("SELECT SUM(v) AS s,AVG(v) AS a,SUM(DISTINCT v) AS d,AVG(v) FILTER(WHERE g>?) AS f FROM t")) {
                dump(statement, 1);
                dump(statement, (Object) null);
                commands.execute("INSERT INTO t VALUES('Infinity',2)");
                dump(statement, 1);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT SUM(v) AS s,MIN(v) AS lo,MAX(v) AS hi FROM t")) {
                dump(statement);
                commands.execute("INSERT INTO t VALUES('-Infinity',2)");
                dump(statement);
            }
            commands.execute("CREATE TABLE source(v DECFLOAT(5))");
            commands.execute("INSERT INTO source VALUES(1.25),(2.5)");
            try (PreparedStatement statement = connection.prepareStatement("CREATE TABLE saved(v DECFLOAT(10) DEFAULT (SELECT SUM(v)+CAST(? AS DECFLOAT(3)) FROM source))")) {
                statement.setString(1, "1.25");
                statement.execute();
            }
            commands.execute("INSERT INTO saved DEFAULT VALUES");
            commands.execute("INSERT INTO source VALUES(1)");
            commands.execute("INSERT INTO saved DEFAULT VALUES");
            try (PreparedStatement statement = connection.prepareStatement("TABLE saved")) {
                dump(statement);
            }
            commands.execute("CREATE TABLE doubles(v DOUBLE)");
            commands.execute("INSERT INTO doubles VALUES(1.25),(2.5),(NULL)");
            try (PreparedStatement statement = connection.prepareStatement("SELECT SUM(v) AS s,AVG(v) AS a FROM doubles")) {
                dump(statement);
                commands.execute("INSERT INTO doubles VALUES('Infinity')");
                dump(statement);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT SUM(v) AS s FROM doubles")) {
                dump(statement);
            }
            for (String sql : new String[] {"SELECT CAST('NaN' AS DECFLOAT)/0 WHERE FALSE", "SELECT MOD(CAST(1 AS DECFLOAT),0) WHERE FALSE"}) {
                try (PreparedStatement statement = connection.prepareStatement(sql)) {
                    System.out.println("P\tprepared");
                } catch (SQLException error) {
                    System.out.println("P\t" + error.getErrorCode() + "\t" + error.getSQLState());
                }
            }
        }
    }
}
