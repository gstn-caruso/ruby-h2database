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
    ruby "test/reference/mvstore.rb"
    ruby "test/reference/sql_storage.rb"
  end
end

task default: :test
