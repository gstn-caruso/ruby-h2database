import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Types;
import java.util.Base64;

public class FloatingArithmeticOracle {
    private static String encode(String text) {
        return Base64.getEncoder().encodeToString(text.getBytes(StandardCharsets.UTF_8));
    }

    private static void dump(ResultSet result) throws Exception {
        var metadata = result.getMetaData();
        for (int i = 1; i <= metadata.getColumnCount(); i++) {
            String type = metadata.getColumnTypeName(i).replace("DOUBLE PRECISION", "DOUBLE")
                    .replace("CHARACTER VARYING", "VARCHAR");
            System.out.println("M\t" + encode(metadata.getColumnLabel(i)) + "\t" + encode(type) + "\t"
                    + metadata.getPrecision(i) + "\t" + metadata.getScale(i));
        }
        while (result.next()) {
            StringBuilder row = new StringBuilder("R");
            for (int i = 1; i <= metadata.getColumnCount(); i++) {
                String text = result.getString(i);
                row.append('\t');
                if (text == null) {
                    row.append('N');
                } else if (metadata.getColumnTypeName(i).equals("REAL")) {
                    row.append('F').append(Integer.toHexString(Float.floatToIntBits(result.getFloat(i))));
                } else if (metadata.getColumnTypeName(i).equals("DOUBLE PRECISION")) {
                    row.append('D').append(Long.toHexString(Double.doubleToLongBits(result.getDouble(i))));
                } else {
                    if (!metadata.getColumnTypeName(i).equals("DECFLOAT") &&
                            (metadata.getColumnType(i) == Types.NUMERIC || metadata.getColumnType(i) == Types.DECIMAL)) {
                        text = new BigDecimal(text).stripTrailingZeros().toPlainString();
                    }
                    row.append('V').append(encode(text));
                }
            }
            System.out.println(row);
        }
    }

    private static void execute(PreparedStatement statement, Object... values) throws Exception {
        try {
            for (int i = 0; i < values.length; i++) {
                statement.setObject(i + 1, values[i]);
            }
            dump(statement.executeQuery());
        } catch (SQLException error) {
            System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
        }
        System.out.println("END");
    }

    public static void main(String[] arguments) throws Exception {
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:floating_arithmetic")) {
            if (arguments.length == 0) {
                try (var input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
                        Statement statement = connection.createStatement()) {
                    for (String line; (line = input.readLine()) != null;) {
                        String sql = new String(Base64.getDecoder().decode(line), StandardCharsets.UTF_8);
                        try {
                            if (statement.execute(sql)) {
                                dump(statement.getResultSet());
                            } else {
                                System.out.println("U\t" + statement.getUpdateCount());
                            }
                        } catch (SQLException error) {
                            System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
                        }
                        System.out.println("END");
                    }
                }
            } else {
                Object[][] values = {{"0.1","0.2"},{"0.3","0.4"},{"3.4028235e38","2"},
                        {"1.4e-45","2"},{"NaN","0"},{"NaN","2"},{"Infinity","-Infinity"},
                        {null,"bad"},{"bad",null},{null,"0"},{"1","0.5f"},{"1","bad"},
                        {0.1,0.2},{Double.NaN,Double.NaN},{Double.POSITIVE_INFINITY,0},
                        {new BigDecimal("1.0000000596046448"),new BigDecimal("0.1")}};
                for (String type : new String[] {"REAL","DOUBLE","FLOAT(7)","FLOAT(25)"}) {
                    for (String operator : new String[] {"+","-","*","/","%"}) {
                        try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS " + type + ") "
                                + operator + " CAST(? AS " + type + ") AS v")) {
                            for (Object[] pair : values) {
                                execute(statement, pair);
                            }
                        }
                    }
                }
                for (String sql : new String[] {"SELECT CAST(? AS REAL)+CAST(? AS VARCHAR) AS v",
                        "SELECT CAST(? AS VARCHAR)+(CAST(? AS REAL)/CAST(0 AS REAL)) AS v",
                        "SELECT MOD(CAST(? AS REAL),CAST(? AS VARCHAR)) AS v"}) {
                    try (PreparedStatement statement = connection.prepareStatement(sql)) {
                        for (Object[] pair : values) {
                            execute(statement, pair);
                        }
                    }
                }
                for (String sql : new String[] {"SELECT CAST(1 AS REAL)/CAST(0 AS REAL) WHERE FALSE",
                        "SELECT CAST('NaN' AS REAL)%CAST(0 AS REAL) WHERE FALSE", "SELECT MOD(CAST(? AS REAL),'bad')",
                        "SELECT MOD(?,?)", "SELECT CAST(? AS REAL)+?", "SELECT CAST(NULL AS REAL)+'bad'",
                        "SELECT MOD(CAST(NULL AS REAL),'bad')", "SELECT CAST(? AS REAL)+CAST(? AS VARCHAR)",
                        "SELECT MOD('1','2')", "SELECT MOD(NULL,NULL)"}) {
                    try (PreparedStatement statement = connection.prepareStatement(sql)) {
                        System.out.println("P\tprepared");
                    } catch (SQLException error) {
                        System.out.println("P\t" + error.getErrorCode() + "\t" + error.getSQLState());
                    }
                    System.out.println("END");
                }
            }
        }
    }
}
