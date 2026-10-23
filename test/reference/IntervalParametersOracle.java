import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import org.h2.api.Interval;
import org.h2.api.IntervalQualifier;

public class IntervalParametersOracle {
    private static void emit(ResultSet result) throws Exception {
        int count = result.getMetaData().getColumnCount();
        for (int column = 1; column <= count; column++) {
            System.out.println("M\t" + result.getMetaData().getColumnLabel(column) + "\t"
                    + result.getMetaData().getColumnTypeName(column) + "\t"
                    + result.getMetaData().getPrecision(column) + "\t" + result.getMetaData().getScale(column));
        }
        while (result.next()) {
            StringBuilder row = new StringBuilder("R");
            for (int column = 1; column <= count; column++) {
                row.append('\t').append(result.getString(column));
            }
            System.out.println(row);
        }
    }

    public static void main(String[] arguments) throws Exception {
        long[] remaining = {0, 0, 0, 0, 0, 123456789, 2, 2, 123, 7384123456789L, 2, 123123456789L, 2123456789L};
        StringBuilder schema = new StringBuilder("CREATE TABLE t(id INT PRIMARY KEY");
        StringBuilder names = new StringBuilder();
        for (IntervalQualifier qualifier : IntervalQualifier.values()) {
            int index = qualifier.ordinal();
            schema.append(",c").append(index).append(' ').append(qualifier.getTypeName(5, qualifier.hasSeconds() ? 9 : -1));
            if (index != 0) names.append(',');
            names.append('c').append(index);
        }
        schema.append(')');
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:interval_parameters")) {
            try (Statement statement = connection.createStatement()) { statement.execute(schema.toString()); }
            try (PreparedStatement statement = connection.prepareStatement("INSERT INTO t VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)")) {
                for (int row = 0; row < 4; row++) {
                    statement.setInt(1, row);
                    for (IntervalQualifier qualifier : IntervalQualifier.values()) {
                        int index = qualifier.ordinal();
                        statement.setObject(index + 2, row == 3 ? null : new Interval(qualifier, row == 1,
                                row == 2 ? 0 : 1, row == 2 ? 0 : remaining[index]));
                    }
                    System.out.println("U\t" + statement.executeUpdate());
                }
            }
            try (Statement statement = connection.createStatement(); ResultSet result = statement.executeQuery("SELECT " + names + " FROM t ORDER BY id")) { emit(result); }
            try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS INTERVAL DAY(5) TO SECOND(3)) AS v")) {
                statement.setObject(1, new Interval(IntervalQualifier.DAY_TO_SECOND, true, 1, 7384123456789L));
                try (ResultSet result = statement.executeQuery()) { emit(result); }
            }
            try (Statement statement = connection.createStatement(); ResultSet result = statement.executeQuery("SELECT (DATE '2001-02-01'-DATE '2000-01-01') YEAR AS forced,INTERVAL '1.999999999' SECOND(2,0) AS literal,AVG(c2) AS average,SUM(c2) AS total FROM t")) { emit(result); }
        }
    }
}
