module main

import os
import sync
import net
import toml
import time
import veb
import net.http
import net.urllib

pub struct Context {
	veb.Context
}

const server_name = 'Tiniest Veb Server'
const default_mime_type = 'application/octet-stream'
const allowed_methods = [http.Method.get, .head]!
const allow_header = 'GET, HEAD, OPTIONS'
const range_chunk_size = 64 * 1024
// Each range is sent by its own thread: above this number of ranges being
// sent, a request for a range gets the whole file, streamed by veb.
const max_range_streams = 64
// A request with one of these headers is not answered with a range.
const preconditions = [http.CommonHeader.if_match, .if_none_match, .if_modified_since,
	.if_unmodified_since]!

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

// set_headers adds the configured headers to a response.
fn (config HeadersConfig) set_headers(mut ctx Context) {
	ctx.set_header(.server, server_name)
	ctx.set_header(.cache_control, config.cache_control)
	ctx.set_header(.expires, time.utc().add_seconds(config.expiration_delay).http_header_string())
}

// custom_headers returns a middleware adding the configured headers to a response.
fn custom_headers(config HeadersConfig) veb.MiddlewareOptions[Context] {
	return veb.MiddlewareOptions[Context]{
		after:   true
		handler: fn [config] (mut ctx Context) bool {
			config.set_headers(mut ctx)
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

// register_unknown_mime_types makes veb serve the files it has no MIME type
// for as binary data, instead of refusing to serve the whole folder.
fn (mut static_files StaticFiles) register_unknown_mime_types(folder string) {
	for file in os.walk_ext(folder, '', hidden: true) {
		ext := os.file_ext(file).to_lower()
		if ext != '' && ext !in veb.mime_types {
			static_files.static_mime_types[ext] = default_mime_type
		}
	}
}

// remove_hidden_directories stops serving the content of the hidden
// directories veb has scanned, like `.git`. `.well-known` is kept.
fn (mut static_files StaticFiles) remove_hidden_directories() {
	for url_path in static_files.static_files.keys() {
		if url_path.split('/').any(it.starts_with('.') && it != '.well-known') {
			static_files.static_files.delete(url_path)
			static_files.static_hosts.delete(url_path)
		}
	}
}

// restrict_methods returns a middleware refusing the methods that make no
// sense for static files, which veb would otherwise answer like a `GET`.
fn restrict_methods() veb.MiddlewareOptions[Context] {
	return veb.MiddlewareOptions[Context]{
		handler: fn (mut ctx Context) bool {
			if ctx.req.method in allowed_methods {
				return true
			}

			ctx.set_header(.allow, allow_header)
			if ctx.req.method == .options {
				ctx.no_content()
				// a 204 response must not have a `Content-Length` header
				ctx.res.header.delete(.content_length)
			} else {
				ctx.res.set_status(.method_not_allowed)
				ctx.text('405 Method Not Allowed')
			}
			// veb sets its own `Server` header when it prepares the response
			ctx.set_header(.server, server_name)
			return false
		}
	}
}

struct CachedEtag {
	size  u64
	mtime i64
	etag  string
}

// EtagCache keeps the ETag of the files requested by ranges: veb hashes the
// whole file to compute it, which is too slow to do for each part of a file.
@[heap]
struct EtagCache {
mut:
	mutex &sync.Mutex = sync.new_mutex()
	etags map[string]CachedEtag
}

// get returns the ETag veb computes for a file. The file is only hashed again
// when its size or its modification time has changed: a file rewritten with
// the same size within the same second keeps its previous ETag here.
fn (mut cache EtagCache) get(file string) !string {
	size := os.file_size(file)
	mtime := os.file_last_mod_unix(file)

	cache.mutex.lock()
	cached := cache.etags[file]
	cache.mutex.unlock()
	if cached.etag != '' && cached.size == size && cached.mtime == mtime {
		return cached.etag
	}

	etag := veb.static_file_etag(file)!
	cache.mutex.lock()
	cache.etags[file] = CachedEtag{
		size:  size
		mtime: mtime
		etag:  etag
	}
	cache.mutex.unlock()
	return etag
}

// find_file returns the path of the file veb serves for a request path.
fn (static_files &StaticFiles) find_file(request_path string) ?string {
	if !request_path.ends_with('/') {
		return static_files.static_files[request_path] or { return none }
	}

	for index in ['index.html', 'index.htm'] {
		if file := static_files.static_files[request_path + index] {
			return file
		}
	}
	return none
}

// send_range writes a partial response, a chunk of the file at a time, on a
// connection taken over from veb, then closes it: the client has to open a
// new one for its next request.
fn send_range(mut conn net.TcpConn, head string, file os.File, start i64, length i64, mut streams sync.Semaphore) {
	mut reader := file
	defer {
		reader.close()
		conn.close() or {}
		streams.post()
	}

	// veb makes a connection blocking when it is taken over, and the write
	// timeout only applies to a non-blocking one: without it, a client which
	// stops reading would keep this thread forever
	conn.set_blocking(false) or { return }
	conn.write_string(head) or { return }
	mut buffer := []u8{len: range_chunk_size}
	mut sent := i64(0)
	for sent < length {
		mut chunk := if length - sent < buffer.len { buffer[..int(length - sent)] } else { buffer }
		read := reader.read_from(u64(start + sent), mut chunk) or { return }
		if read == 0 {
			return
		}
		conn.write(chunk[..read]) or { return }
		sent += read
	}
}

// redirect_to_directories returns a middleware redirecting the request for
// a directory with an index to its path with a trailing slash, which veb
// answers with a 404. The page is not served directly: without the slash, its
// relative links would be resolved against the parent directory.
fn redirect_to_directories(static_files &StaticFiles, config HeadersConfig) veb.MiddlewareOptions[Context] {
	return veb.MiddlewareOptions[Context]{
		handler: fn [static_files, config] (mut ctx Context) bool {
			url := urllib.parse(ctx.req.url) or { return true }
			// a host in the request target, like in `//host/path`, would end up
			// in the redirection: such a request is not redirected, even when
			// the host is this server
			if url.host != '' || !url.path.starts_with('/') || url.path.starts_with('//')
				|| url.path.ends_with('/') || url.path in static_files.static_files {
				return true
			}
			static_files.find_file(url.path + '/') or { return true }

			query := if url.raw_query == '' { '' } else { '?${url.raw_query}' }
			ctx.redirect('${url.escaped_path()}/${query}', typ: .moved_permanently)
			// a browser would otherwise keep the redirection forever; veb also
			// sets its own `Server` header when it prepares the response
			config.set_headers(mut ctx)
			return false
		}
	}
}

// serve_ranges returns a middleware answering the `GET` requests for a single
// range of a file, which veb ignores: it streams the files and always sends
// them entirely. Any other request is left to veb.
fn serve_ranges(static_files &StaticFiles, config HeadersConfig) veb.MiddlewareOptions[Context] {
	mut etags := &EtagCache{}
	mut streams := sync.new_semaphore_init(max_range_streams)

	return veb.MiddlewareOptions[Context]{
		handler: fn [static_files, config, mut etags, mut streams] (mut ctx Context) bool {
			range_header := ctx.req.header.get(.range) or { return true }
			if ctx.req.method != .get || preconditions.any(ctx.req.header.contains(it)) {
				return true
			}

			url := urllib.parse(ctx.req.url) or { return true }
			file := static_files.find_file(url.path) or { return true }
			size := i64(os.file_size(file))
			etag := etags.get(file) or { return true }
			if !veb.if_range_holds(ctx.req.header.get(.if_range) or { '' }, etag, 0) {
				return true
			}
			range := veb.parse_range_header(range_header, size) or { return true }

			if range.start >= size {
				ctx.res.set_status(.requested_range_not_satisfiable)
				ctx.set_header(.content_range, 'bytes */${size}')
				ctx.text('')
				// veb sets its own `Server` header when it prepares the response
				ctx.set_header(.server, server_name)
				return false
			}

			mut reader := os.open(file) or { return true }
			if !streams.try_wait() {
				reader.close()
				return true
			}

			ext := os.file_ext(file).to_lower()
			length := range.end - range.start + 1
			config.set_headers(mut ctx)
			ctx.set_header(.content_type, static_files.static_mime_types[ext] or {
				veb.mime_types[ext]
			})
			ctx.set_header(.content_length, length.str())
			ctx.set_header(.content_range, 'bytes ${range.start}-${range.end}/${size}')
			ctx.set_header(.accept_ranges, 'bytes')
			ctx.set_header(.etag, etag)
			ctx.set_header(.last_modified, time.unix(os.file_last_mod_unix(file)).http_header_string())
			ctx.set_header(.vary, 'Accept-Encoding')
			ctx.set_header(.connection, 'close')
			head := 'HTTP/1.1 206 Partial Content\r\n${ctx.res.header.render(version: .v1_1)}\r\n'

			// veb streams the whole files without loading them, but can only
			// send a part of a file from memory: the range is sent from here
			ctx.takeover_conn()
			spawn send_range(mut ctx.conn, head, reader, range.start, length, mut streams)
			return false
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
	static_files.register_unknown_mime_types(folder)
	static_files.handle_static(folder, true)!
	static_files.remove_hidden_directories()
	static_files.use(restrict_methods())
	static_files.use(redirect_to_directories(static_files, headers_config))
	static_files.use(serve_ranges(static_files, headers_config))
	static_files.use(custom_headers(headers_config))

	// The empty path is deliberate: with '/', veb strips it from the URL and
	// `GET /` would not match the root index anymore.
	mut app := &App{}
	app.register_controller[StaticFiles, Context]('', mut static_files)!
	println("Server is started, serving '${folder}' folder")
	veb.run[App, Context](mut app, port)
}
