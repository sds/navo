# Marina

`marina` is a framework for testing Chef cookbooks within Docker containers.

It takes inspiration from the
[test-kitchen](https://github.com/test-kitchen/test-kitchen) and
[kitchen-docker](https://github.com/portertech/kitchen-docker) projects, but
sacrifices these tools' flexibility and generic implementations for an
opinionated workflow. If you ever need to test your Chef cookbooks in something
other than a Docker container, you should use those tools instead.

* [Requirements](#requirements)
* [Installation](#installation)
* [License](#license)

## Requirements

* Ruby 2.0.0+

## Installation

```bash
gem install marina
```

## License

This project is released under the [MIT license](LICENSE.md).
