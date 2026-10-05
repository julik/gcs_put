# frozen_string_literal: true

require_relative "lib/gcs_put/version"

Gem::Specification.new do |spec|
  spec.name = "gcs_put"
  spec.version = GCSPut::VERSION
  spec.authors = ["Julik Tarkhanov"]
  spec.email = ["me@julik.nl"]
  spec.license = "MIT"
  spec.summary = "Streaming resumable uploads to Google Cloud Storage without knowing the size in advance."
  spec.description = "Gives you a writable IO-like object which streams what you write into it to a GCS object using " \
    "the resumable upload protocol over a signed URL. The size of the upload does not need to be known beforehand."

  spec.homepage = "https://github.com/julik/gcs_put"
  # The homepage link on rubygems.org only appears if you add homepage_uri. Just spec.homepage is not enough.
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.required_ruby_version = ">= 3.2.0" # google-cloud-storage wants 3.2

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.files = `git ls-files -z`.split("\x0").reject do |path|
    path.start_with?("tmp/", "test/", ".github/") || File.basename(path) == "Gemfile.lock"
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "google-cloud-storage", "~> 1.40"

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "webmock"
  spec.add_development_dependency "faraday"
  spec.add_development_dependency "magic_frozen_string_literal"
  spec.add_development_dependency "standard", ">= 1.35.1"
end
