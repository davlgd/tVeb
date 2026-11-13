module main

import os
import net
import toml
import time
import veb

pub struct Context {
	veb.Context
}

const server_name = 'Tiniest Veb Server'

struct HeadersConfig {
	cache_control    string = 'public, max-age=3600'
	expiration_delay int    = 3600
}

pub struct App {
	veb.Controller
}

// StaticFiles serves the files through a controller: veb serves the static
// files of the main app before any middleware runs, while a controller serves
// them between its before and after middlewares, where headers can be added.
pub struct StaticFiles {
	veb.StaticHandler
	veb.Middleware[Context]
}

fn print_help() {
	println("usage: ${os.args[0]} [folder_to_serve] [port] (default: 'public', 8080)")
}

fn get_settings() (string, int, string) {
	mut folder := 'public'
	mut port := 8080
	mut error_msg := ''

	if os.args.len > 3 {
		return '', 0, 'error: too many arguments'
	}

	for arg in os.args[1..] {
		if arg == '--help' || arg == '-h' {
			return '', 0, ''
		}
	}

	if os.args.len > 1 {
		is_arg1_port := os.args[1].int() != 0 && !os.is_dir(os.args[1])

		match os.args.len {
			3 {
				folder = os.args[1]
				port = os.args[2].int()
			}
			2 {
				if is_arg1_port {
					port = os.args[1].int()
				} else {
					folder = os.args[1]
				}
			}
			else {}
		}
	}

	return folder, port, error_msg
}

pub fn (mut ctx Context) not_found() veb.Result {
	folder, _, _ := get_settings()
	mut file_path := '404.html'

	if folder != '/' {
		file_path = '${folder}/${file_path}'
	}

	content := os.read_file(file_path) or { '<h1>Page not found!</h1>' }

	ctx.res.set_status(.not_found)
	result := ctx.html(content)
	// veb sets its own `Server` header when it prepares the response
	ctx.set_header(.server, server_name)
	return result
}

// load_headers_config reads the optional `headers.toml` file, a missing file
// or a missing value falls back to the defaults.
fn load_headers_config(path string) !HeadersConfig {
	defaults := HeadersConfig{}
	if !os.exists(path) {
		return defaults
	}

	doc := toml.parse_file(path)!
	cache_control := doc.value('cache_control').default_to(defaults.cache_control)
	expiration_delay := doc.value('expiration_delay').default_to(defaults.expiration_delay)

	if cache_control !is string {
		return error('`cache_control` must be a string')
	}
	if expiration_delay !is int && expiration_delay !is i64 {
		return error('`expiration_delay` must be an integer')
	}

	return HeadersConfig{
		cache_control:    cache_control.string()
		expiration_delay: expiration_delay.int()
	}
}

// custom_headers returns a middleware adding the configured headers to a response.
fn custom_headers(config HeadersConfig) veb.MiddlewareOptions[Context] {
	return veb.MiddlewareOptions[Context]{
		after:   true
		handler: fn [config] (mut ctx Context) bool {
			ctx.set_header(.server, server_name)
			ctx.set_header(.cache_control, config.cache_control)
			ctx.set_header(.expires, time.utc().add_seconds(config.expiration_delay).http_header_string())
			return true
		}
	}
}

// is_address_in_use tells if a listening error means that the address is
// already used: `net` only reports the error number in its message.
fn is_address_in_use(err IError) bool {
	$if windows {
		return err.msg().contains('${net.WsaError.wsaeaddrinuse}')
	} $else {
		return err.msg().contains('socket error: ${int(C.EADDRINUSE)};')
	}
}

// check_port fails when the server can't listen on the port. It tries the
// wildcard and loopback addresses of both families: veb listens on IPv6 by
// default, and asks to kill any process it finds listening on the port.
fn check_port(port int) ! {
	for family, hosts in {
		net.AddrFamily.ip6: ['', '[::1]']
		net.AddrFamily.ip:  ['', '127.0.0.1']
	} {
		for host in hosts {
			mut listener := net.listen_tcp(family, '${host}:${port}') or {
				if is_address_in_use(err) {
					return error('the port ${port} seems to be busy')
				}
				if host == '' {
					return error("can't listen on the port ${port}: ${err.msg()}")
				}
				// a loopback address may not exist on this host
				continue
			}
			listener.close() or {}
		}
	}
}

fn main() {
	folder, port, error_msg := get_settings()

	if error_msg != '' {
		eprintln(error_msg)
		print_help()
		exit(1)
	}

	if folder == '' && port == 0 {
		print_help()
		exit(0)
	}

	if !os.is_dir(folder) {
		eprintln("error: '${folder}' folder doesn't exist and can't be served")
		exit(1)
	}

	if port < 1 || port > 65535 {
		eprintln('error: ${port} is an invalid port number')
		exit(1)
	}

	headers_config := load_headers_config('headers.toml') or {
		eprintln('error: invalid headers.toml file: ${err.msg()}')
		exit(1)
	}

	check_port(port) or {
		eprintln('error: ${err.msg()}')
		exit(1)
	}

	mut static_files := &StaticFiles{}
	static_files.handle_static(folder, true)!
	static_files.use(custom_headers(headers_config))

	// The empty path is deliberate: with '/', veb strips it from the URL and
	// `GET /` would not match the root index anymore.
	mut app := &App{}
	app.register_controller[StaticFiles, Context]('', mut static_files)!
	println("Server is started, serving '${folder}' folder")
	veb.run[App, Context](mut app, port)
}
