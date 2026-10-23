require_relative "lib/h2/version"

Gem::Specification.new do |spec|
  spec.name = "ruby-h2database"
  spec.version = H2::VERSION
  spec.summary = "A native Ruby port of the H2 SQL database engine"
  spec.description = "H2's SQL engine, being migrated from Java to modern Ruby. See MIGRATION.md for compatibility and remaining work."
  spec.authors = ["H2 Group", "Ruby H2 contributors"]
  spec.homepage = "https://github.com/gstn-caruso/ruby-h2database"
  spec.licenses = ["MPL-2.0", "EPL-1.0"]
  spec.required_ruby_version = ">= 3.4", "< 5"
  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "MIGRATION.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = ["h2"]
  spec.require_paths = ["lib"]
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/MIGRATION.md"
  spec.add_dependency "bigdecimal", ">= 3.1", "< 5"
  spec.add_dependency "optparse", ">= 0.6", "< 1"
  spec.add_dependency "strscan", "~> 3.1"
end
