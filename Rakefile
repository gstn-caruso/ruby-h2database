require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
end

namespace :test do
  desc "Compare SQL and MVStore behavior against the built Java reference"
  task :reference do
    Dir["test/fixtures/*_reference.sql"].sort.each { ruby "test/reference/compare.rb", it }
    ruby "test/reference/binary_values.rb"
    ruby "test/reference/set_queries.rb"
    ruby "test/reference/common_tables.rb"
    ruby "test/reference/temporal.rb"
    ruby "test/reference/date_functions.rb"
    ruby "test/reference/calendar.rb"
    ruby "test/reference/intervals.rb"
    ruby "test/reference/session_context.rb"
    ruby "test/reference/mvstore.rb"
    ruby "test/reference/sql_storage.rb"
    ruby "test/reference/transactions.rb"
    ruby "test/reference/persistence.rb"
  end
end

task default: :test
