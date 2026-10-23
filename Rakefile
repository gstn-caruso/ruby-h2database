require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
end

namespace :test do
  desc "Compare relational SQL against the built Java reference"
  task :reference do
    ruby "test/reference/compare.rb"
  end
end

task default: :test
