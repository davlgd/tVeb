# Changelog

All notable changes to Tiniest Veb Server (tVeb) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Commit messages after the 0.2.0 release follow the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) specification.

## [0.2.1] - 2026-11-13

### Fixed

- Rename the `error` variable to `error_msg` to fix a V compiler notice (it shadowed the builtin `error` function)

## [0.2.0] - 2024-09-29

### Changed

- Migrate from `x.vweb` to `veb`
- Rename project to `Tiniest Veb Server (tVeb)`

## [0.1.5] - 2024-02-18

### Added

- Check if the port is available before starting the server

### Changed

- Use new native `http_header_string()` to form headers date/time stamps

## [0.1.4] - 2024-02-18

### Added

- HTTP headers can be customized via the `headers.toml` file

## [0.1.3] - 2024-02-17

### Added

- Add custom `server` HTTP header
- Add `Cache-Control` HTTP header
- Add `Last-Modified` HTTP header
- Add `Expires` HTTP header

## [0.1.2] - 2024-02-17

### Added

- Add support to `404.html` files (at the root of the served folder)

### Changed

- Factorize the code to better handle settings and errors

## [0.1.1] - 2024-02-12

### Added

- User can now set the port of the server (default is `8080`)
- Changelog

### Fixed

- Fixes to better handle arguments

## [0.1.0] - 2024-02-10

### Added

- Initial public release

[0.2.1]: https://github.com/davlgd/tVeb/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/davlgd/tVeb/compare/v0.1.5...v0.2.0
[0.1.5]: https://github.com/davlgd/tVeb/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/davlgd/tVeb/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/davlgd/tVeb/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/davlgd/tVeb/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/davlgd/tVeb/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/davlgd/tVeb/releases/tag/v0.1.0
