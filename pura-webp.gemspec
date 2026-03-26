# frozen_string_literal: true

require_relative "lib/pura/webp/version"

Gem::Specification.new do |spec|
  spec.name = "pura-webp"
  spec.version = Pura::Webp::VERSION
  spec.authors = ["komagata"]
  spec.summary = "Pure Ruby WebP decoder/encoder"
  spec.description = "A pure Ruby WebP decoder and encoder with zero C extension dependencies. " \
                     "Supports VP8 lossy decoding and VP8L lossless encoding."
  spec.homepage = "https://github.com/komagata/pura-webp"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.files = Dir["lib/**/*.rb", "LICENSE", "README.md"]

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
