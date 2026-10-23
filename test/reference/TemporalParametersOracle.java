import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;

public class TemporalParametersOracle {
    public static void main(String[] arguments) throws Exception {
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:temporal_parameters")) {
            try (Statement statement = connection.createStatement()) {
                statement.execute("CREATE TABLE t(d DATE,t TIME(9),ts TIMESTAMP(9))");
            }
            Object[][] rows = {
                {LocalDate.of(2000, 2, 29), LocalTime.of(23, 59, 59, 123456789), LocalDateTime.of(2000, 1, 2, 3, 4, 5, 123456789)},
                {LocalDate.of(0, 2, 29), LocalTime.of(0, 0, 0, 1), LocalDateTime.of(-400, 2, 29, 0, 0)},
                {null, null, null}
            };
            try (PreparedStatement insert = connection.prepareStatement("INSERT INTO t VALUES(?,?,?)")) {
                for (Object[] row : rows) {
                    for (int i = 0; i < row.length; i++) {
                        insert.setObject(i + 1, row[i]);
                    }
                    System.out.println("U\t" + insert.executeUpdate());
                }
            }
            try (Statement statement = connection.createStatement(); ResultSet result = statement.executeQuery("TABLE t ORDER BY d NULLS LAST")) {
                for (int column = 1; column <= 3; column++) {
                    System.out.println("M\t" + result.getMetaData().getColumnLabel(column) + "\t"
                            + result.getMetaData().getColumnTypeName(column) + "\t"
                            + result.getMetaData().getPrecision(column) + "\t" + result.getMetaData().getScale(column));
                }
                while (result.next()) {
                    System.out.println("R\t" + result.getString(1) + "\t" + result.getString(2) + "\t" + result.getString(3));
                }
            }
        }
    }
}
