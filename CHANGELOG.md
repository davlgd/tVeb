# Tiniest vWeb Server

## 0.1.5 (2024-02-18)

- Check if the port is available before starting the server
- Use new native `http_header_string()` to form headers date/time stamps

## 0.1.4 (2024-02-18)

- HTTP headers can be customized via the `headers.toml` file

## 0.1.3 (2024-02-17)

- Add custom `server` HTTP header
- Add `Cache-Control` HTTP header
- Add `Last-Modified` HTTP header
- Add `Expires` HTTP header

## 0.1.2 (2024-02-17)

- Add support to `404.html` files (at the root of the served folder)
- Factorize the code to better handle settings and errors

## 0.1.1 (2024-02-12)

- User can now set the port of the server (default is `8080`)
- Fixes to better handle arguments
- Changelog

## 0.1.0 (2024-02-10)

- Initial public release
