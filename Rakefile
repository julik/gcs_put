# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "standard/rake"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task :format do
  `bundle exec standardrb --fix`
  `bundle exec magic_frozen_string_literal .`
end

task :generate_typedefs do
  # Types from other gems (URI, Faraday, Google::Cloud::Storage) are not resolvable for sord, hence the untyped fallback
  `bundle exec sord --replace-errors-with-untyped rbi/gcs_put.rbi`
  `bundle exec sord --replace-errors-with-untyped sig/gcs_put.rbs`
end

# When building the gem, generate typedefs beforehand so that they get included
Rake::Task["build"].enhance(["generate_typedefs"])

task default: [:test, :standard, :generate_typedefs]
