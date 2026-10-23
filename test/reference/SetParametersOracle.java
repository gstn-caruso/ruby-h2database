import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Types;

public class SetParametersOracle {
    public static void main(String[] statements) throws Exception {
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:set_parameters")) {
            for (String sql : statements) {
                for (Integer value : new Integer[] {1, -1, null}) {
                    String label = sql + " [" + value + "]:";
                    try (PreparedStatement statement = connection.prepareStatement(sql)) {
                        if (value == null) {
                            statement.setNull(1, Types.INTEGER);
                        } else {
                            statement.setInt(1, value);
                        }
                        try (ResultSet result = statement.executeQuery()) {
                            StringBuilder line = new StringBuilder(label);
                            while (result.next()) {
                                line.append(' ').append(result.getString(1));
                            }
                            System.out.println(line);
                        }
                    } catch (SQLException error) {
                        System.out.println(label + " ERROR " + error.getErrorCode());
                    }
                }
            }
        }
    }
}
