import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;

public class DateFunctionsParametersOracle {
    public static void main(String[] arguments) throws Exception {
        Object[] counts = {1L, -1L, null, new BigDecimal("0.5"), new BigDecimal("-0.5"), -0.5d, 2147483648L};
        String[][] cases = {
            {"SELECT DATEADD(month,?,CAST(? AS DATE)) AS a,DATEDIFF(day,CAST(? AS DATE),CAST(? AS DATE)) AS d", "2000-01-31", "2000-02-01"},
            {"SELECT DATEADD(ns,?,CAST(? AS TIMESTAMP(9))) AS a,DATEDIFF(mcs,CAST(? AS TIMESTAMP(9)),CAST(? AS TIMESTAMP(9))) AS d", "2000-01-31 23:59:59.999999999", "2000-02-01 00:00:00.000000001"},
            {"SELECT DATEADD(second,?,CAST(? AS TIME(9))) AS a,DATEDIFF(second,CAST(? AS TIME(9)),CAST(? AS TIME(9))) AS d", "23:59:59.123456789", "00:00:00.000000001"}
        };
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:date_functions_parameters")) {
            for (String[] test : cases) {
                try (PreparedStatement statement = connection.prepareStatement(test[0])) {
                    for (Object count : counts) {
                        statement.setObject(1, count);
                        statement.setString(2, test[1]);
                        statement.setString(3, test[1]);
                        statement.setString(4, test[2]);
                        try (ResultSet result = statement.executeQuery()) {
                            for (int column = 1; column <= 2; column++) {
                                System.out.println("M\t" + result.getMetaData().getColumnLabel(column) + "\t"
                                        + result.getMetaData().getColumnTypeName(column) + "\t"
                                        + result.getMetaData().getPrecision(column) + "\t" + result.getMetaData().getScale(column));
                            }
                            result.next();
                            System.out.println("R\t" + result.getString(1) + "\t" + result.getString(2));
                        } catch (SQLException error) {
                            System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
                        }
                    }
                }
            }
        }
    }
}
