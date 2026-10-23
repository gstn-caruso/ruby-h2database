import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.util.Base64;

public class CTEParametersOracle {
    private static String encode(String value) {
        return Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }

    public static void main(String[] statements) throws Exception {
        Object[][][] bindings = {
            {{10, 2, 14}, {100, 3, 103}, {null, 2, 14}},
            {{10, 2, 14}, {100, 3, 103}, {null, 2, 14}},
            {{1, "a", 1, "a", 1, "b"}, {2, "x", 1, "y", 2, "z"}},
            {{1}, {2}}
        };
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:cte_parameters")) {
            for (int i = 0; i < statements.length; i++) {
                try (PreparedStatement statement = connection.prepareStatement(statements[i])) {
                    for (int j = 0; j < bindings[i].length; j++) {
                        System.out.println("CASE " + i + "/" + j);
                        for (int p = 0; p < bindings[i][j].length; p++) {
                            statement.setObject(p + 1, bindings[i][j][p]);
                        }
                        try (ResultSet result = statement.executeQuery()) {
                            ResultSetMetaData metadata = result.getMetaData();
                            StringBuilder header = new StringBuilder("H");
                            for (int column = 1; column <= metadata.getColumnCount(); column++) {
                                String type = metadata.getColumnTypeName(column);
                                header.append('\t').append(encode(metadata.getColumnLabel(column)))
                                        .append(':').append("CHARACTER VARYING".equals(type) ? "VARCHAR" : type);
                            }
                            System.out.println(header);
                            while (result.next()) {
                                StringBuilder row = new StringBuilder("R");
                                for (int column = 1; column <= metadata.getColumnCount(); column++) {
                                    String value = result.getString(column);
                                    row.append('\t').append(value == null ? "N" : "V" + encode(value));
                                }
                                System.out.println(row);
                            }
                        }
                    }
                } catch (SQLException error) {
                    for (int j = 0; j < bindings[i].length; j++) {
                        System.out.println("CASE " + i + "/" + j);
                        System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
                    }
                }
            }
        }
    }
}
