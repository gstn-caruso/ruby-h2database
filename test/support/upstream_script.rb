# frozen_string_literal: true

class UpstreamScript
  Scenario = Data.define(:path, :line, :sql, :expected, :scalar)

  def initialize(path)
    @path = path
  end

  def cases
    scenarios = []
    sql = +""
    line_number = nil
    File.foreach(@path).with_index(1) do |line, number|
      line = line.strip
      next if line.empty? || line.start_with?("--")

      if line.start_with?(">")
        raise "Expectation without a statement at #{@path}:#{number}" if scenarios.empty?

        scenarios.last.expected << line.sub(/\A>>?\s?/, "")
        if line.start_with?(">>")
          scenarios[-1] = scenarios.last.with(scalar: true)
        end
      else
        line_number ||= number
        sql << line << "\n"
        if line.end_with?(";")
          scenarios << Scenario.new(@path, line_number, sql.strip, [], false)
          sql = +""
          line_number = nil
        end
      end
    end
    raise "Unfinished statement in #{@path}" unless sql.empty?

    scenarios
  end
end
