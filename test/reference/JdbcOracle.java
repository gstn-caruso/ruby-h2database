import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Types;
import java.util.Base64;

public class JdbcOracle {
    private static String encode(String value) {
        return Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }

    public static void main(String[] arguments) throws Exception {
        try (Connection connection = arguments.length == 0
                    ? DriverManager.getConnection("jdbc:h2:mem:ruby_reference")
                    : DriverManager.getConnection(arguments[0], arguments.length > 1 ? arguments[1] : "sa", arguments.length > 2 ? arguments[2] : "");
                BufferedReader input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8))) {
            for (String line; (line = input.readLine()) != null;) {
                String sql = new String(Base64.getDecoder().decode(line), StandardCharsets.UTF_8);
                try (Statement statement = connection.createStatement()) {
                    if (statement.execute(sql)) {
                        try (ResultSet result = statement.getResultSet()) {
                            ResultSetMetaData metadata = result.getMetaData();
                            StringBuilder labels = new StringBuilder("Q");
                            StringBuilder types = new StringBuilder("T");
                            for (int column = 1; column <= metadata.getColumnCount(); column++) {
                                labels.append('\t').append(encode(metadata.getColumnLabel(column)));
                                types.append('\t').append(encode(metadata.getColumnTypeName(column)));
                            }
                            System.out.println(labels);
                            System.out.println(types);
                            while (result.next()) {
                                StringBuilder row = new StringBuilder("R");
                                for (int column = 1; column <= metadata.getColumnCount(); column++) {
                                    int type = metadata.getColumnType(column);
                                    if ((type == Types.BINARY || type == Types.VARBINARY || type == Types.LONGVARBINARY)
                                            && !"UUID".equals(metadata.getColumnTypeName(column))) {
                                        byte[] value = result.getBytes(column);
                                        row.append('\t').append(value == null ? "N" : "B" + Base64.getEncoder().encodeToString(value));
                                    } else {
                                        String value = result.getString(column);
                                        row.append('\t').append(value == null ? "N" : "V" + encode(value));
                                    }
                                }
                                System.out.println(row);
                            }
                        }
                    } else {
                        System.out.println("U\t" + statement.getUpdateCount());
                    }
                } catch (SQLException exception) {
                    System.out.println("E\t" + exception.getErrorCode() + "\t" + exception.getSQLState());
                }
                System.out.println("END");
            }
        }
    }
}
