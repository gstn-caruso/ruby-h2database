import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Savepoint;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.LocalTime;

public class SessionClockOracle {
    private static String clock(PreparedStatement statement) throws Exception {
        try (ResultSet result = statement.executeQuery()) {
            result.next();
            return result.getString(1);
        }
    }

    private static void metadata(Connection connection, String sql) throws Exception {
        try (Statement statement = connection.createStatement(); ResultSet result = statement.executeQuery(sql)) {
            for (int i = 1; i <= result.getMetaData().getColumnCount(); i++) {
                System.out.println("M\t" + result.getMetaData().getColumnLabel(i) + "\t"
                        + result.getMetaData().getColumnTypeName(i) + "\t"
                        + result.getMetaData().getPrecision(i) + "\t" + result.getMetaData().getScale(i));
            }
        }
    }

    public static void main(String[] arguments) throws Exception {
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:session_clock");
                Connection other = DriverManager.getConnection("jdbc:h2:mem:session_clock");
                Statement commands = connection.createStatement();
                PreparedStatement statement = connection.prepareStatement("SELECT LOCALTIMESTAMP(9)")) {
            metadata(connection, "SELECT CURRENT_DATE(),LOCALTIME,LOCALTIMESTAMP,CURDATE(),CURTIME(),NOW()");
            for (int scale = 0; scale <= 9; scale++) {
                metadata(connection, "SELECT LOCALTIME(" + scale + "),LOCALTIMESTAMP(" + scale
                        + "),CURTIME(" + scale + "),NOW(" + scale + ")");
            }
            String first = clock(statement);
            Thread.sleep(5);
            System.out.println("C\tautocommit refresh\t" + !first.equals(clock(statement)));
            connection.setAutoCommit(false);
            first = clock(statement);
            Thread.sleep(5);
            System.out.println("C\ttransaction snapshot\t" + first.equals(clock(statement)));
            try (PreparedStatement second = other.prepareStatement("SELECT LOCALTIMESTAMP(9)")) {
                System.out.println("C\tindependent connection\t" + !first.equals(clock(second)));
            }
            Savepoint savepoint = connection.setSavepoint("keep_clock");
            System.out.println("C\tsavepoint keeps clock\t" + first.equals(clock(statement)));
            connection.rollback(savepoint);
            System.out.println("C\trollback to savepoint refresh\t" + !first.equals(clock(statement)));
            first = clock(statement);
            Thread.sleep(5);
            try {
                commands.execute("SELECT 1/0");
            } catch (SQLException error) {
                System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
            }
            System.out.println("C\tfailed statement keeps clock\t" + first.equals(clock(statement)));
            try {
                commands.execute("ROLLBACK TO SAVEPOINT missing");
            } catch (SQLException error) {
                System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
            }
            System.out.println("C\tfailed rollback refresh\t" + !first.equals(clock(statement)));
            first = clock(statement);
            Thread.sleep(5);
            commands.execute("CREATE TABLE reset_clock(v INT)");
            System.out.println("C\tDDL refresh\t" + !first.equals(clock(statement)));
            first = clock(statement);
            Thread.sleep(5);
            connection.commit();
            System.out.println("C\tcommit refresh\t" + !first.equals(clock(statement)));
            first = clock(statement);
            Thread.sleep(5);
            connection.rollback();
            System.out.println("C\trollback refresh\t" + !first.equals(clock(statement)));
            try (PreparedStatement cast = connection.prepareStatement("SELECT CAST(? AS TIMESTAMP(9))="
                    + "CAST(CURRENT_DATE AS TIMESTAMP)+CAST(? AS TIME(9)) AS v")) {
                LocalTime[] values = {LocalTime.MIDNIGHT, LocalTime.of(12, 34, 56, 123456789), LocalTime.MAX, null};
                for (LocalTime value : values) {
                    cast.setObject(1, value);
                    cast.setObject(2, value);
                    try (ResultSet result = cast.executeQuery()) {
                        result.next();
                        System.out.println("P\t" + result.getString(1));
                    }
                }
            }
        }
    }
}
