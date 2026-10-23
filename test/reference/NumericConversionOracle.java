import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

public class NumericConversionOracle {
    private static void dump(PreparedStatement statement, Object value) throws Exception {
        try {
            statement.setObject(1, value);
            try (ResultSet result = statement.executeQuery()) {
                var metadata = result.getMetaData();
                System.out.println("M\t" + metadata.getColumnLabel(1) + "\t"
                        + metadata.getColumnTypeName(1).replace("DOUBLE PRECISION", "DOUBLE").replace("CHARACTER VARYING", "VARCHAR") + "\t"
                        + metadata.getPrecision(1) + "\t" + metadata.getScale(1));
                while (result.next()) {
                    String type = metadata.getColumnTypeName(1);
                    Object item = (type.equals("REAL") || type.equals("DOUBLE PRECISION")) ? result.getObject(1) : null;
                    String text;
                    if (item instanceof Float) {
                        text = Integer.toHexString(Float.floatToIntBits((Float) item));
                    } else if (item instanceof Double) {
                        text = Long.toHexString(Double.doubleToLongBits((Double) item));
                    } else {
                        text = result.getString(1);
                    }
                    System.out.println("R\t" + text);
                }
            }
        } catch (SQLException error) {
            System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
        }
    }

    public static void main(String[] arguments) throws Exception {
        if (arguments.length > 0 && arguments[0].equals("floating-format")) {
            System.out.println("J\t" + Runtime.version());
            System.out.println("F\t" + Float.toString(2147483648f));
            System.out.println("D\t" + Double.toString(0x1p128));
            return;
        }
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:numeric_conversion");
                Statement commands = connection.createStatement()) {
            Object[] values = {null, true, false, 1, -128, 128, 2147483648L, Long.MAX_VALUE,
                    new BigDecimal("1.0000000596046448"), new BigDecimal("9223372036854775807.1"),
                    0.285, Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY,
                    "1.0000000596046448", "7.006492321624086e-46", "3.4028235677973367e38",
                    "0x1.00000100000000000001p0", "0x0.000000000000000000001p-65",
                    "1_0", "128", "１２٣", "１２.٣٤", "0.5f", "true", "NaN", new byte[] {0,0,0,1}, "2147483648", "0x1p128"};
            for (String type : new String[] {"TINYINT", "SMALLINT", "INT", "BIGINT", "NUMERIC(8,2)",
                    "DECIMAL(8,2)", "NUMBER", "NUMBER(6,2)", "DECFLOAT(8)", "REAL", "DOUBLE", "FLOAT(7)", "FLOAT(25)", "BOOLEAN", "VARCHAR"}) {
                try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS " + type + ") AS v")) {
                    for (Object value : values) {
                        dump(statement, value);
                    }
                }
            }
            for (String source : new String[] {"REAL", "DOUBLE", "DECFLOAT", "NUMERIC(30,20)"}) {
                for (String type : new String[] {"NUMERIC(8,2)", "REAL", "DOUBLE", "BOOLEAN", "VARCHAR"}) {
                    try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(CAST(? AS " + source + ") AS " + type + ") AS v")) {
                        for (Object value : new Object[] {"0.285", "1.0000000596046448", "NaN", "Infinity", null}) {
                            dump(statement, value);
                        }
                    }
                }
            }
            for (String sql : new String[] {"SELECT CAST('1_0' AS INT) WHERE FALSE", "SELECT CAST('128' AS TINYINT) WHERE FALSE",
                    "SELECT CAST(NULL AS FLOAT(54))", "SELECT CAST(NULL AS NUMERIC(100001))", "SELECT CAST(NULL AS NUMERIC(2,-1))"}) {
                try (PreparedStatement statement = connection.prepareStatement(sql)) {
                    System.out.println("P\tprepared");
                } catch (SQLException error) {
                    System.out.println("P\t" + error.getErrorCode() + "\t" + error.getSQLState());
                }
            }
        }
    }
}
