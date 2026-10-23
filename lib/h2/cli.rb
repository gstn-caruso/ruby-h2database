# frozen_string_literal: true

require "optparse"
require_relative "../h2"

module H2
  class CLI
    def run(arguments, input: $stdin, output: $stdout, error: $stderr)
      options = {}
      parser = OptionParser.new do |command|
        command.banner = "Usage: h2 [--execute SQL | FILE.sql]\nExecute a SQL script in a new in-memory Ruby H2 database."
        command.on("-e", "--execute SQL", "Execute SQL") { options[:sql] = it }
        command.on("-v", "--version", "Print version") { options[:version] = true }
        command.on("-h", "--help", "Print help") { options[:help] = true }
      end
      remaining = parser.parse(arguments)
      if options[:help] || options[:version]
        output.puts(options[:help] ? parser : "Ruby H2 #{VERSION}")
        return 0
      end
      if remaining.length > 1 || (options[:sql] && !remaining.empty?)
        raise OptionParser::InvalidArgument, "provide either --execute or one SQL file"
      end
      sql = options[:sql] || (remaining.empty? ? input.read : File.read(remaining.first))
      H2.connect do |connection|
        connection.execute_script(sql).each { render(it, output) }
      end
      0
    rescue Error, OptionParser::ParseError, SystemCallError => exception
      error.puts(exception.message)
      1
    end

    private

    def render(result, output)
      if result.query?
        output.puts(result.columns.map { format_value(it) }.join("\t"))
        result.rows.each { |row| output.puts(row.map { format_value(it) }.join("\t")) }
        count = result.rows.length
        output.puts("(#{count} #{count == 1 ? 'row' : 'rows'})")
      else
        output.puts(result.update_count.zero? ? "OK" : "Update count: #{result.update_count}")
      end
    end

    def format_value(value)
      case value
      when nil then "NULL"
      when true then "TRUE"
      when false then "FALSE"
      when BigDecimal then value.to_s("F")
      else value.to_s.gsub(/[\\\t\n\r]/) { {"\\" => "\\\\", "\t" => "\\t", "\n" => "\\n", "\r" => "\\r"}.fetch(it) }
      end
    end
  end
end
