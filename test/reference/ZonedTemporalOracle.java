import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.OffsetDateTime;
import java.time.OffsetTime;
import java.time.ZoneOffset;
import java.time.zone.ZoneRulesProvider;

public class ZonedTemporalOracle {
    private static void dump(PreparedStatement statement, Object... values) throws Exception {
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
    }

    public static void main(String[] arguments) throws Exception {
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:zoned_temporal");
                Statement commands = connection.createStatement()) {
            System.out.println("D\t" + ZoneRulesProvider.getVersions("Africa/Casablanca").lastKey());
            for (int year : new int[] {2400, 1000000000}) {
                for (int month : new int[] {1, 7}) {
                    try (ResultSet result = commands.executeQuery("SELECT EXTRACT(timezone_hour FROM TIMESTAMP WITH TIME ZONE '"
                            + year + "-" + String.format("%02d", month) + "-15 12:34:56.123456789 Africa/Casablanca')*3600")) {
                        result.next();
                        System.out.println("Z\t" + year + "\t" + month + "\t" + result.getInt(1));
                    }
                }
            }
            commands.execute("SET TIME ZONE '+03'");
            try (PreparedStatement statement = connection.prepareStatement("SELECT CURRENT_TIME AS t,CURRENT_TIMESTAMP AS ts WHERE FALSE")) {
                dump(statement);
            }
            OffsetTime time = OffsetTime.of(23, 59, 59, 999999999, ZoneOffset.ofHoursMinutesSeconds(-3, -30, -15));
            OffsetDateTime timestamp = OffsetDateTime.of(2000, 2, 28, 23, 59, 59, 999999999, ZoneOffset.ofHours(3));
            for (int scale : new int[] {0, 1, 3, 6, 9}) {
                try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS TIME(" + scale
                        + ") WITH TIME ZONE) AS t,CAST(? AS TIMESTAMP(" + scale + ") WITH TIME ZONE) AS ts")) {
                    dump(statement, time, timestamp);
                    dump(statement, null, null);
                }
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS TIME(9)) AS t,"
                    + "CAST(? AS TIMESTAMP(9)) AS ts,CAST(? AS DATE) AS d")) {
                dump(statement, time, timestamp, timestamp);
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT TIMESTAMP WITH TIME ZONE "
                    + "'2000-01-01 12:00:00' AS l,CAST('2000-01-01 12:00:00' AS TIMESTAMP WITH TIME ZONE) AS c,"
                    + "CAST(? AS TIMESTAMP WITH TIME ZONE) AS p,EXTRACT(timezone_hour FROM DATE '2000-01-01') AS h")) {
                commands.execute("SET TIME ZONE '-05'");
                dump(statement, "2000-01-01 12:00:00");
            }
            try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS TIMESTAMP(9) WITH TIME ZONE) AT TIME ZONE ? AS v")) {
                dump(statement, timestamp, "UTC");
                dump(statement, timestamp, "America/New_York");
                dump(statement, timestamp, null);
            }
            commands.execute("SET TIME ZONE '+03'");
            commands.execute("CREATE TABLE defaults(frozen TIMESTAMP WITH TIME ZONE DEFAULT CAST('2000-01-01 12:00:00' AS TIMESTAMP WITH TIME ZONE),"
                    + "variable TIMESTAMP WITH TIME ZONE DEFAULT CAST(TIMESTAMP '2000-01-01 12:00:00' AS TIMESTAMP WITH TIME ZONE),"
                    + "coalesced TIME WITH TIME ZONE DEFAULT COALESCE(TIME '12:00:00',TIME WITH TIME ZONE '12:00:00Z'))");
            try (PreparedStatement create = connection.prepareStatement("CREATE TABLE bound(t TIME WITH TIME ZONE DEFAULT CAST(? AS TIME WITH TIME ZONE))")) {
                create.setString(1, "12:00:00");
                create.execute();
            }
            commands.execute("SET TIME ZONE '-05'");
            commands.execute("INSERT INTO defaults DEFAULT VALUES");
            commands.execute("INSERT INTO bound DEFAULT VALUES");
            try (PreparedStatement statement = connection.prepareStatement("SELECT * FROM defaults")) {
                dump(statement);
            }
            try (PreparedStatement statement = connection.prepareStatement("TABLE bound")) {
                dump(statement);
            }
            commands.execute("SET TIME ZONE 'UTC'");
            connection.setAutoCommit(false);
            try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(TIME '12:00:00' AS TIMESTAMP)")) {
                long boundary = System.currentTimeMillis();
                Thread.sleep(10);
                try (ResultSet result = commands.executeQuery("SELECT CURRENT_TIMESTAMP(9)")) {
                    result.next();
                    long captured = result.getObject(1, OffsetDateTime.class).toInstant().toEpochMilli();
                    System.out.println("C\tcast preparation captures clock\t" + (captured <= boundary));
                }
            }
        }
    }
}
