import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

public class NumericRoundingOracle {
    private static void dump(PreparedStatement statement, Object... values) throws Exception {
        try {
            for (int i = 0; i < values.length; i++) {
                statement.setObject(i + 1, values[i]);
            }
            try (ResultSet result = statement.executeQuery()) {
                for (int i = 1; i <= result.getMetaData().getColumnCount(); i++) {
                    String type = result.getMetaData().getColumnTypeName(i).replace("DOUBLE PRECISION", "DOUBLE");
                    System.out.println("M\t" + result.getMetaData().getColumnLabel(i) + "\t" + type + "\t"
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
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:numeric_rounding");
                Statement commands = connection.createStatement()) {
            Object[][] pairs = {{"1.255", 2}, {"-1.255", 1}, {null, 0}, {"1.25", null}, {"1.25", 4}, {"127", -1},
                    {"1.25", "bad"}, {null, "bad"}, {"1.25", 100001}, {"1.25", Double.NaN}, {"1.25", Double.NEGATIVE_INFINITY}};
            for (String type : new String[] {"NUMERIC(8,3)", "DECFLOAT(8)", "REAL", "DOUBLE", "TINYINT", "BIGINT"}) {
                for (String name : new String[] {"ROUND", "TRUNC"}) {
                    try (PreparedStatement statement = connection.prepareStatement("SELECT " + name + "(CAST(? AS " + type + "),?) AS v")) {
                        for (Object[] pair : pairs) {
                            dump(statement, pair);
                        }
                    }
                }
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT ROUND(CAST(? AS NUMERIC(8,3)),NULL) AS n,TRUNC(CAST(? AS DECFLOAT(8)),NULL) AS d")) {
                dump(statement, "1.25", "1.25");
                dump(statement, null, null);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT TRUNC(CAST(? AS DATE)) AS d,TRUNC(CAST(? AS TIMESTAMP(3))) AS t,TRUNC(CAST(? AS VARCHAR)) AS s")) {
                dump(statement, "2000-02-29", "2000-02-29 12:34:56.789", "2000-02-29 12:34:56");
                dump(statement, null, null, null);
                dump(statement, "bad", "bad", "bad");
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT FLOOR(CAST(? AS REAL)) AS r,CEIL(CAST(? AS DOUBLE)) AS d,ROUNDMAGIC(?) AS m")) {
                dump(statement, "NaN", "Infinity", "0.30000000000000004");
                dump(statement, "-Infinity", "NaN", "0.00000000000001");
                dump(statement, null, null, null);
            }
            commands.execute("CREATE TABLE t(n NUMERIC(10,2),s INT)");
            commands.execute("INSERT INTO t VALUES(99999999.99,1)");
            try (PreparedStatement statement = connection.prepareStatement("SELECT ROUND(n,-1) AS a,ROUND(n,1) AS b,ROUND(n,2) AS c,ROUND(n,s) AS d,TRUNC(n,-1) AS e FROM t")) {
                dump(statement);
            }
            commands.execute("CREATE TABLE source(n NUMERIC(8,3),s INT)");
            commands.execute("INSERT INTO source VALUES(1.255,2)");
            try (PreparedStatement statement = connection.prepareStatement("CREATE TABLE saved(n NUMERIC(9,3) DEFAULT (SELECT ROUND(n,s) FROM source),p NUMERIC(9,3) DEFAULT ROUND((SELECT n FROM source),?))")) {
                statement.setInt(1, 1);
                statement.execute();
            }
            commands.execute("INSERT INTO saved DEFAULT VALUES");
            commands.execute("UPDATE source SET n=-1.255,s=1");
            commands.execute("INSERT INTO saved DEFAULT VALUES");
            try (PreparedStatement statement = connection.prepareStatement("TABLE saved ORDER BY n")) {
                dump(statement);
            }
            for (String sql : new String[] {"SELECT ROUND(NULL,'bad') WHERE FALSE", "SELECT ROUND(1,100001) WHERE FALSE",
                    "SELECT FLOOR('1') WHERE FALSE", "SELECT TRUNC(DATE '2000-01-01',0) WHERE FALSE", "SELECT ROUND(?)"}) {
                try (PreparedStatement statement = connection.prepareStatement(sql)) {
                    System.out.println("P\tprepared");
                } catch (SQLException error) {
                    System.out.println("P\t" + error.getErrorCode() + "\t" + error.getSQLState());
                }
            }
        }
    }
}
