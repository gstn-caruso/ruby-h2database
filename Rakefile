require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
end

namespace :test do
  desc "Compare SQL fixtures against the built Java reference"
  task :reference do
    Dir["test/fixtures/*_reference.sql"].sort.each { ruby "test/reference/compare.rb", it }
  end
end

task default: :test
