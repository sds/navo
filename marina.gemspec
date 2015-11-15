$LOAD_PATH << File.expand_path('../lib', __FILE__)
require 'marina/constants'
require 'marina/version'

Gem::Specification.new do |s|
  s.name             = 'marina'
  s.version          = Marina::VERSION
  s.license          = 'MIT'
  s.summary          = 'Test Chef cookbooks in Docker containers'
  s.description      = s.summary
  s.authors          = ['Shane da Silva']
  s.email            = ['shane@dasilva.io']
  s.homepage         = Marina::REPO_URL

  s.require_paths    = ['lib']

  s.executables      = ['marina']

  s.files            = Dir['lib/**/*.rb']

  s.required_ruby_version = '>= 2.0.0'

  s.add_dependency 'berkshelf', '~> 4.0'
  s.add_dependency 'docker-api', '~> 1.22'
  s.add_dependency 'thor', '~> 0'
end
