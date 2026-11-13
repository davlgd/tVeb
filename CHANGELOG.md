# Changelog

All notable changes to Tiniest Veb Server (tVeb) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Commit messages after the 0.2.0 release follow the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) specification.

## [Unreleased]

### Changed

- The project is now distributed under the Apache 2.0 license, with a `LICENSE` file: `v.mod` declared MIT before

## [0.3.0] - 2026-11-13

### Added

- The server stops gracefully on `SIGINT`, `SIGTERM` and `SIGHUP`: it no longer accepts connections and gives 8 seconds to the requests being answered to complete ([#14](https://github.com/davlgd/tVeb/issues/14))
- Optional compression of the text files with zstd and gzip, enabled with `compression = true` in `headers.toml`: they are compressed once when the server starts, in the temporary folder of the system or the `compression_folder` one ([#11](https://github.com/davlgd/tVeb/issues/11))
- Custom headers added to every response, defined in a `[headers]` table of `headers.toml` ([#12](https://github.com/davlgd/tVeb/issues/12))
- Optional access log, enabled with `access_log = true` in `headers.toml`: a JSON line on the standard output for each response ([#13](https://github.com/davlgd/tVeb/issues/13))
- Files without extension are served, with a type guessed from their content, pages and XML documents as plain text ([#15](https://github.com/davlgd/tVeb/issues/15))
- Files added while the server runs are served, a removed one gets the not found page ([#15](https://github.com/davlgd/tVeb/issues/15))

### Fixed

- A busy port is detected on Windows too, where listening on a port already used by another program succeeds: the server now also tries to connect to it, which delays its start by about two seconds there ([#4](https://github.com/davlgd/tVeb/issues/4))

## [0.2.1] - 2026-11-13

### Fixed

- Rename the `error` variable to `error_msg` to fix a V compiler notice (it shadowed the builtin `error` function)
- Not found pages (unknown paths) use the `404` status code, even with a `404.html` file, and the custom `Server` header; they no longer send `Cache-Control`, `Expires` and `Last-Modified` headers ([#2](https://github.com/davlgd/tVeb/issues/2))
- `headers.toml` is optional and read once at startup: a missing file no longer crashes the server, an invalid one is reported before it starts ([#5](https://github.com/davlgd/tVeb/issues/5))
- Custom headers from `headers.toml` are sent again with static files: recent V versions serve them before any middleware runs ([#1](https://github.com/davlgd/tVeb/issues/1))
- Building from the repository root (`v -prod .`) works again with recent V versions, which no longer support the `src/` directory: sources are now at the root ([#3](https://github.com/davlgd/tVeb/issues/3))
- A busy port is detected again before the server starts, on IPv4 and IPv6: veb no longer asks to kill the process using it ([#4](https://github.com/davlgd/tVeb/issues/4))
- A file with an extension unknown to veb no longer prevents the server from starting: it is served as `application/octet-stream`. The content of hidden directories such as `.git` is not served, `.well-known` excepted ([#6](https://github.com/davlgd/tVeb/issues/6))
- Requests with a method other than `GET` or `HEAD` are no longer answered like a `GET`: `OPTIONS` gets a `204` response and the other ones a `405`, both with an `Allow` header ([#7](https://github.com/davlgd/tVeb/issues/7))
- The version declared in `v.mod` is up to date again, it was still `0.1.5` ([#9](https://github.com/davlgd/tVeb/issues/9))
- `GET` requests for a single range of a file get a `206` partial response (`416` when it cannot be satisfied) instead of the whole file, which makes download resuming and media seeking work ([#8](https://github.com/davlgd/tVeb/issues/8))
- A directory with an index requested without its trailing slash is redirected to it (`301`) instead of returning a `404` ([#17](https://github.com/davlgd/tVeb/issues/17))

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

[Unreleased]: https://github.com/davlgd/tVeb/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/davlgd/tVeb/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/davlgd/tVeb/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/davlgd/tVeb/compare/v0.1.5...v0.2.0
[0.1.5]: https://github.com/davlgd/tVeb/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/davlgd/tVeb/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/davlgd/tVeb/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/davlgd/tVeb/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/davlgd/tVeb/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/davlgd/tVeb/releases/tag/v0.1.0
