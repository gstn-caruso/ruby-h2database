import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;

public class CalendarParametersOracle {
    private static void emit(ResultSet result) throws Exception {
        int count = result.getMetaData().getColumnCount();
        for (int column = 1; column <= count; column++) {
            System.out.println("M\t" + result.getMetaData().getColumnLabel(column) + "\t"
                    + result.getMetaData().getColumnTypeName(column) + "\t"
                    + result.getMetaData().getPrecision(column) + "\t" + result.getMetaData().getScale(column));
        }
        result.next();
        StringBuilder row = new StringBuilder("R");
        for (int column = 1; column <= count; column++) {
            String value = result.getString(column);
            if (value != null && result.getMetaData().getColumnTypeName(column).equals("NUMERIC")) {
                value = result.getBigDecimal(column).stripTrailingZeros().toPlainString();
            }
            row.append('\t').append(value);
        }
        System.out.println(row);
    }

    public static void main(String[] arguments) throws Exception {
        String[][] cases = {
            {"SELECT DATE_TRUNC(year,CAST(? AS DATE)) AS v,LAST_DAY(?) AS d,EXTRACT(epoch FROM CAST(? AS DATE)) AS e", "1900-02-15", "0000-02-29", "2016-01-01", null},
            {"SELECT DATE_TRUNC(mcs,CAST(? AS TIME(3))) AS v,EXTRACT(epoch FROM CAST(? AS TIME(9))) AS e,EXTRACT(iso_week_year FROM CAST(? AS TIME(9))) AS y", "00:00:00", "00:00:00.000000001", "23:59:59.123456789", null},
            {"SELECT DATE_TRUNC(week_year,CAST(? AS TIMESTAMP(3))) AS v,LAST_DAY(?) AS d,EXTRACT(epoch FROM CAST(? AS TIMESTAMP(9))) AS e", "1969-12-31 23:59:59.999999999", "0000-02-29 00:00:00.000000001", "2016-01-01 12:34:56.123456789", null}
        };
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:calendar_parameters")) {
            for (String[] test : cases) {
                try (PreparedStatement statement = connection.prepareStatement(test[0])) {
                    for (int index = 1; index < test.length; index++) {
                        for (int parameter = 1; parameter <= 3; parameter++) {
                            statement.setString(parameter, test[index]);
                        }
                        try (ResultSet result = statement.executeQuery()) {
                            emit(result);
                        }
                    }
                }
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT EXTRACT(epoch FROM TIME '00:00:00') AS v,EXTRACT(epoch FROM TIME '00:00:00.000000001') AS f,EXTRACT(epoch FROM DATE '-1000000000-01-01') AS d"); ResultSet result = statement.executeQuery()) {
                emit(result);
            }
        }
    }
}
