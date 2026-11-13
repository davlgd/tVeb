module main

import os
import rand
import sync
import sync.stdatomic
import net
import toml
import time
import veb
import net.http
import net.urllib
import compress.gzip
import compress.zstd

pub struct Context {
	veb.Context
}

const server_name = 'Tiniest Veb Server'
// The headers set by the server itself, which can't be customized.
const reserved_headers = ['accept-ranges', 'allow', 'cache-control', 'connection', 'content-encoding',
	'content-length', 'content-range', 'content-type', 'date', 'etag', 'expires', 'keep-alive',
	'last-modified', 'location', 'proxy-connection', 'server', 'te', 'trailer', 'transfer-encoding',
	'upgrade', 'vary']!
const default_mime_type = 'application/octet-stream'
// The kinds of files worth compressing, the other ones already are.
const compressible_extensions = ['.css', '.csv', '.eot', '.htm', '.html', '.ico', '.ics', '.js',
	'.json', '.jsonld', '.md', '.mjs', '.otf', '.svg', '.ttf', '.txt', '.wasm', '.xhtml', '.xml']!
// A larger file is not compressed.
const max_compressed_size = 1024 * 1024
const allowed_methods = [http.Method.get, .head]!
const allow_header = 'GET, HEAD, OPTIONS'
const range_chunk_size = 64 * 1024
// Each range is sent by its own thread: above this number of ranges being
// sent, a request for a range gets the whole file, streamed by veb.
const max_range_streams = 64
// The time given to the requests being answered when the server is stopped,
// a bit less than the 10 seconds `docker stop` waits before killing it.
const shutdown_timeout = time.Duration(8 * time.second)
// Set by the handler of the termination signals, which can't do more safely.
const stop_requested = stdatomic.new_atomic(false)
// When the server began to stop, in milliseconds since the Unix epoch.
const stop_started_at = stdatomic.new_atomic(i64(0))
// A request with one of these headers is not answered with a range.
const preconditions = [http.CommonHeader.if_match, .if_none_match, .if_modified_since,
	.if_unmodified_since]!

struct Config {
	cache_control    string = 'public, max-age=3600'
	expiration_delay int    = 3600
	compression      bool
	access_log       bool
	headers          map[string]string
}

pub struct App {
	veb.Controller
mut:
	server &veb.Server = unsafe { nil }
}

// init_server is called by veb with the handle used to stop the server.
pub fn (mut app App) init_server(server &veb.Server) {
	app.server = server
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

// not_found_page returns the `404.html` file of the served folder, or a
// default page.
fn not_found_page(folder string) string {
	return os.read_file(os.join_path(folder, '404.html')) or { '<h1>Page not found!</h1>' }
}

// not_found is called by veb for the requests nothing answered. It does not
// know the configuration: the `not_found_pages` middleware answers first.
pub fn (mut ctx Context) not_found() veb.Result {
	folder, _, _ := get_settings()

	ctx.res.set_status(.not_found)
	result := ctx.html(not_found_page(folder))
	// veb sets its own `Server` header when it prepares the response
	ctx.set_header(.server, server_name)
	return result
}

// load_config reads the optional `headers.toml` file, a missing file
// or a missing value falls back to the defaults.
fn load_config(path string) !Config {
	defaults := Config{}
	if !os.exists(path) {
		return defaults
	}

	doc := toml.parse_file(path)!
	cache_control := doc.value('cache_control').default_to(defaults.cache_control)
	expiration_delay := doc.value('expiration_delay').default_to(defaults.expiration_delay)
	compression := doc.value('compression').default_to(defaults.compression)
	access_log := doc.value('access_log').default_to(defaults.access_log)

	if cache_control !is string {
		return error('`cache_control` must be a string')
	}
	if expiration_delay !is int && expiration_delay !is i64 {
		return error('`expiration_delay` must be an integer')
	}
	if compression !is bool {
		return error('`compression` must be a boolean')
	}
	if access_log !is bool {
		return error('`access_log` must be a boolean')
	}

	mut headers := map[string]string{}
	headers_table := doc.value('headers')
	if headers_table !is toml.Null {
		if headers_table !is map[string]toml.Any {
			return error('`headers` must be a table')
		}
		mut checker := http.new_header()
		for name, value in headers_table.as_map() {
			if value !is string {
				return error('the `${name}` header must be a string')
			}
			if name.to_lower() in reserved_headers {
				return error("the `${name}` header is set by the server and can't be customized")
			}
			if headers.keys().any(it.to_lower() == name.to_lower()) {
				return error('the `${name}` header is defined twice')
			}
			if value.string().bytes().any(it == 0x7f || (it < 0x20 && it != `\t`)) {
				return error('the `${name}` header contains a control character')
			}
			checker.set_custom(name, value.string()) or {
				return error('the `${name}` header is invalid: ${err.msg()}')
			}
			headers[name] = value.string()
		}
	}

	return Config{
		cache_control:    cache_control.string()
		expiration_delay: expiration_delay.int()
		compression:      compression.bool()
		access_log:       access_log.bool()
		headers:          headers
	}
}

// complete_response adds the headers every response gets, then logs it. It
// must be called once the response is prepared: veb sets its own `Server`
// header then.
fn (config Config) complete_response(mut ctx Context) {
	ctx.set_header(.server, server_name)
	for name, value in config.headers {
		ctx.set_custom_header(name, value) or {}
	}
	if config.access_log {
		// written at once: `println` writes the line and its end separately,
		// and the lines of two requests answered together would be mixed
		print(veb.format_access_log(veb.AccessLogOptions{}, &ctx.Context) + '\n')
	}
}

// set_headers adds the configured headers to the response for a file.
fn (config Config) set_headers(mut ctx Context) {
	ctx.set_header(.cache_control, config.cache_control)
	ctx.set_header(.expires, time.utc().add_seconds(config.expiration_delay).http_header_string())
	config.complete_response(mut ctx)
}

// custom_headers returns a middleware adding the configured headers to a response.
fn custom_headers(config Config) veb.MiddlewareOptions[Context] {
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
fn restrict_methods(config Config) veb.MiddlewareOptions[Context] {
	return veb.MiddlewareOptions[Context]{
		handler: fn [config] (mut ctx Context) bool {
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
			config.complete_response(mut ctx)
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

// not_found_pages returns a middleware answering the requests for a path
// which is not served, with the headers of the configuration.
fn not_found_pages(static_files &StaticFiles, config Config, folder string) veb.MiddlewareOptions[Context] {
	return veb.MiddlewareOptions[Context]{
		handler: fn [static_files, config, folder] (mut ctx Context) bool {
			url := urllib.parse(ctx.req.url) or { return true }
			if _ := static_files.find_file(url.path) {
				return true
			}

			ctx.res.set_status(.not_found)
			ctx.html(not_found_page(folder))
			config.complete_response(mut ctx)
			return false
		}
	}
}

// redirect_to_directories returns a middleware redirecting the request for
// a directory with an index to its path with a trailing slash, which veb
// answers with a 404. The page is not served directly: without the slash, its
// relative links would be resolved against the parent directory.
fn redirect_to_directories(static_files &StaticFiles, config Config) veb.MiddlewareOptions[Context] {
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
fn serve_ranges(static_files &StaticFiles, config Config, mut streams sync.Semaphore) veb.MiddlewareOptions[Context] {
	mut etags := &EtagCache{}

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
				config.complete_response(mut ctx)
				return false
			}

			mut reader := os.open(file) or { return true }
			if !streams.try_wait() {
				reader.close()
				return true
			}

			ext := os.file_ext(file).to_lower()
			length := range.end - range.start + 1
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
			ctx.res.set_status(.partial_content)
			config.set_headers(mut ctx)
			head := 'HTTP/1.1 206 Partial Content\r\n${ctx.res.header.render(version: .v1_1)}\r\n'

			// veb streams the whole files without loading them, but can only
			// send a part of a file from memory: the range is sent from here
			ctx.takeover_conn()
			spawn send_range(mut ctx.conn, head, reader, range.start, length, mut streams)
			return false
		}
	}
}

// CompressedFile describes the compressed versions of a file, and the file
// they were made from.
struct CompressedFile {
	size  u64
	mtime i64
	paths map[string]string // by content coding, the preferred one first
}

// accepted_coding returns the first of the `codings` accepted by a client,
// from its `Accept-Encoding` header.
fn accepted_coding(accept_encoding string, codings []string) ?string {
	mut qualities := map[string]f64{}
	for item in accept_encoding.to_lower().split(',') {
		parts := item.split(';')
		mut quality := 1.0
		for param in parts[1..] {
			name, value := param.split_once('=') or { continue }
			if name.trim_space() == 'q' {
				quality = value.trim_space().f64()
			}
		}
		qualities[parts[0].trim_space()] = quality
	}

	for coding in codings {
		quality := qualities[coding] or { qualities['*'] or { 0.0 } }
		if quality > 0 {
			return coding
		}
	}
	return none
}

// compress_files writes the compressed versions of the text files served,
// when they are smaller, in a directory.
fn (static_files &StaticFiles) compress_files(directory string) map[string]CompressedFile {
	mut compressed := map[string]CompressedFile{}
	for file in static_files.static_files.values() {
		ext := os.file_ext(file).to_lower()
		size := os.file_size(file)
		if ext !in compressible_extensions || file in compressed || size > max_compressed_size {
			continue
		}

		mtime := os.file_last_mod_unix(file)
		content := os.read_bytes(file) or { continue }
		mut paths := map[string]string{}
		for coding in ['zstd', 'gzip'] {
			encoded := if coding == 'zstd' {
				zstd.compress(content) or { continue }
			} else {
				gzip.compress(content) or { continue }
			}
			// veb finds the type of a file from its extension
			path := os.join_path(directory, '${compressed.len}.${coding}${ext}')
			if encoded.len < content.len {
				os.write_file_array(path, encoded) or { continue }
				paths[coding] = path
			}
		}
		compressed[file] = CompressedFile{
			size:  size
			mtime: mtime
			paths: paths
		}
	}
	return compressed
}

// serve_compressed returns a middleware sending the compressed version of a
// file to the clients accepting it. A file modified since it was compressed,
// a range of a file and anything else are left to the next handlers.
fn serve_compressed(static_files &StaticFiles, compressed map[string]CompressedFile, config Config) veb.MiddlewareOptions[Context] {
	return veb.MiddlewareOptions[Context]{
		handler: fn [static_files, compressed, config] (mut ctx Context) bool {
			if ctx.req.method !in allowed_methods || ctx.req.header.contains(.range) {
				return true
			}

			accept_encoding := ctx.req.header.get(.accept_encoding) or { return true }
			url := urllib.parse(ctx.req.url) or { return true }
			file := static_files.find_file(url.path) or { return true }
			version := compressed[file] or { return true }
			if os.file_size(file) != version.size || os.file_last_mod_unix(file) != version.mtime {
				return true
			}
			coding := accepted_coding(accept_encoding, version.paths.keys()) or { return true }
			if !os.exists(version.paths[coding]) {
				return true
			}

			// veb sends it like any other file, with its own validators
			ctx.set_header(.content_encoding, coding)
			ctx.file(version.paths[coding])
			ctx.set_header(.vary, 'Accept-Encoding')
			// a range is always a part of the file as it is, not of this version
			ctx.res.header.delete(.accept_ranges)
			config.set_headers(mut ctx)
			return false
		}
	}
}

// enable_compression compresses the text files once, before the server
// starts, in a private directory removed when it stops. veb can compress the
// files itself, but it does so while it answers the first requests for them,
// which then get incomplete responses.
fn (mut static_files StaticFiles) enable_compression(config Config) ! {
	directory := os.join_path(os.temp_dir(), 'tveb_${rand.ulid().to_lower()}')
	os.mkdir(directory, mode: 0o700)!
	at_exit(fn [directory] () {
		os.rmdir_all(directory) or {}
	})!

	println('Compressing the files...')
	static_files.use(serve_compressed(static_files, static_files.compress_files(directory),
		config))
}

fn request_stop(_ os.Signal) {
	mut requested := stop_requested
	requested.store(true)
}

// stop_on_signal waits for a termination signal, then stops the server: veb
// stops accepting connections and answers the requests it already received.
fn (app &App) stop_on_signal() {
	mut requested := stop_requested
	for !requested.load() {
		time.sleep(100 * time.millisecond)
	}

	println('Stopping the server...')
	mut started_at := stop_started_at
	started_at.store(time.now().unix_milli())
	if app.server == unsafe { nil } {
		exit(0)
	}
	// veb ignores a shutdown asked before it is running
	app.server.wait_till_running() or {}
	app.server.shutdown(timeout: shutdown_timeout) or {
		eprintln('error: ${err.msg()}')
		exit(1)
	}
}

// wait_for_range_streams waits for the ranges being sent, which veb does not
// know about: once every stream slot is free, none of them is still running.
fn wait_for_range_streams(mut streams sync.Semaphore) {
	mut started_at := stop_started_at
	deadline := started_at.load() + shutdown_timeout.milliseconds()
	for _ in 0 .. max_range_streams {
		remaining := (deadline - time.now().unix_milli()) * time.millisecond
		if remaining <= 0 || !streams.timed_wait(remaining) {
			eprintln('error: some range requests were still being answered')
			exit(1)
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

	config := load_config('headers.toml') or {
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
	if config.access_log {
		// records when a request arrives, for the duration written in its log
		static_files.use(veb.access_log[Context]().stamp())
	}
	if config.compression {
		static_files.enable_compression(config) or {
			eprintln('warning: compression is disabled: ${err.msg()}')
		}
	}
	static_files.use(restrict_methods(config))
	static_files.use(redirect_to_directories(static_files, config))
	static_files.use(not_found_pages(static_files, config, folder))
	mut range_streams := sync.new_semaphore_init(max_range_streams)
	static_files.use(serve_ranges(static_files, config, mut range_streams))
	static_files.use(custom_headers(config))

	// The empty path is deliberate: with '/', veb strips it from the URL and
	// `GET /` would not match the root index anymore.
	mut app := &App{}
	app.register_controller[StaticFiles, Context]('', mut static_files)!

	os.signal_opt(.int, request_stop)!
	os.signal_opt(.term, request_stop)!
	$if !windows {
		// sent when the terminal which started the server is closed
		os.signal_opt(.hup, request_stop)!
	}
	spawn app.stop_on_signal()

	println("Server is started, serving '${folder}' folder")
	veb.run[App, Context](mut app, port)
	mut requested := stop_requested
	if !requested.load() {
		eprintln('error: the server stopped unexpectedly')
		exit(1)
	}
	wait_for_range_streams(mut range_streams)
	println('Server stopped')
}
