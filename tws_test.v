module main

import io
import os
import net
import net.http
import time

// These tests build the server, run it against a temporary site and check
// its responses, as the behavior of veb changes from one V version to another.

const test_dir = os.join_path(os.vtmp_dir(), 'tveb_test_${os.getpid()}')
const test_exe = os.join_path(test_dir, 'tveb_under_test' + $if windows { '.exe' } $else { '' })

struct TestServer {
	url string
mut:
	process &os.Process
}

fn (mut server TestServer) stop() {
	server.process.signal_kill()
	server.process.wait()
	server.process.close()
}

fn free_port() int {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer {
		listener.close() or {}
	}
	address := listener.addr() or { panic(err) }
	return int(address.port() or { panic(err) })
}

fn new_server_process(work_dir string, port int) &os.Process {
	mut process := os.new_process(test_exe)
	process.set_work_folder(work_dir)
	process.set_args(['site', port.str()])
	process.set_redirect_stdio()
	process.run()
	return process
}

// wait_for_exit returns false when the process is still running after 5 seconds.
fn wait_for_exit(mut process os.Process) bool {
	for _ in 0 .. 50 {
		if !process.is_alive() {
			return true
		}
		time.sleep(100 * time.millisecond)
	}
	return false
}

fn start_server(work_dir string) TestServer {
	port := free_port()
	mut server := TestServer{
		url:     'http://127.0.0.1:${port}'
		process: new_server_process(work_dir, port)
	}

	for _ in 0 .. 50 {
		if !server.process.is_alive() {
			break
		}
		http.get(server.url) or {
			time.sleep(100 * time.millisecond)
			continue
		}
		return server
	}

	output := server.process.stdout_slurp() + server.process.stderr_slurp()
	server.stop()
	panic('the server did not start: ${output}')
}

fn header(res http.Response, key http.CommonHeader) string {
	return res.header.get(key) or { '' }
}

fn make_site(name string) string {
	work_dir := os.join_path(test_dir, name)
	os.mkdir_all(os.join_path(work_dir, 'site', 'css')) or { panic(err) }
	os.write_file(os.join_path(work_dir, 'site', 'index.html'), '<h1>Hello</h1>') or {
		panic(err)
	}
	os.write_file(os.join_path(work_dir, 'site', 'css', 'index.html'), '<h1>CSS</h1>') or {
		panic(err)
	}
	os.write_file(os.join_path(work_dir, 'site', 'css', 'main.css'), 'body {}') or { panic(err) }
	return work_dir
}

fn testsuite_begin() {
	os.mkdir_all(test_dir) or { panic(err) }
	build := os.exec([@VEXE, '-o', test_exe, @DIR])
	assert build.exit_code == 0, build.output
}

fn testsuite_end() {
	os.rmdir_all(test_dir) or {}
}

fn test_static_files_get_the_configured_headers() ! {
	work_dir := make_site('configured')
	os.write_file(os.join_path(work_dir, 'headers.toml'), 'cache_control = "max-age=42"\nexpiration_delay = 42')!
	mut server := start_server(work_dir)
	defer {
		server.stop()
	}

	for path in ['/', '/index.html', '/css/', '/css/main.css'] {
		for method in [http.Method.get, .head] {
			res := http.fetch(url: server.url + path, method: method)!
			assert res.status_code == 200, '${method} ${path}'
			assert header(res, .server) == server_name, '${method} ${path}'
			assert header(res, .cache_control) == 'max-age=42', '${method} ${path}'
			assert res.header.contains(.expires), '${method} ${path}'
			assert res.header.values(.last_modified).len == 1, '${method} ${path}'
		}
	}

	assert http.get(server.url)!.body == '<h1>Hello</h1>'
	assert http.get(server.url + '/css/')!.body == '<h1>CSS</h1>'
	assert header(http.get(server.url + '/css/main.css')!, .content_type) == 'text/css'
}

fn test_not_modified_responses_get_the_configured_headers() ! {
	mut server := start_server(make_site('not_modified'))
	defer {
		server.stop()
	}

	etag := header(http.get(server.url)!, .etag)
	assert etag != ''

	mut request_header := http.new_header()
	request_header.add(.if_none_match, etag)
	res := http.fetch(url: server.url, header: request_header)!
	assert res.status_code == 304
	assert header(res, .server) == server_name
	assert header(res, .cache_control) == 'public, max-age=3600'
}

fn test_headers_file_is_optional() ! {
	mut server := start_server(make_site('defaults'))
	defer {
		server.stop()
	}

	res := http.get(server.url)!
	assert res.status_code == 200
	assert header(res, .server) == server_name
	assert header(res, .cache_control) == 'public, max-age=3600'
	assert res.header.contains(.expires)
}

fn test_invalid_headers_file_is_reported_at_startup() ! {
	for name, content in {
		'malformed':         'cache_control = '
		'wrong_cache':       'cache_control = 42'
		'wrong_delay':       'expiration_delay = "one hour"'
		'wrong_compression': 'compression = "gzip"'
		'headers_not_table': 'headers = "X-Frame-Options: DENY"'
		'header_not_string': '[headers]\nX-Frame-Options = 1'
		'reserved_header':   '[headers]\nContent-Length = "0"'
		'invalid_header':    '[headers]\n"X Frame Options" = "DENY"'
		'hop_by_hop_header': '[headers]\nUpgrade = "h2c"'
		'duplicate_header':  '[headers]\nX-Frame-Options = "DENY"\nx-frame-options = "DENY"'
		'control_character': '[headers]\nX-Frame-Options = "DENY\\u0001"'
	} {
		work_dir := make_site(name)
		os.write_file(os.join_path(work_dir, 'headers.toml'), content)!

		mut process := new_server_process(work_dir, free_port())
		exited := wait_for_exit(mut process)
		if !exited {
			process.signal_kill()
		}
		process.wait()
		errors := process.stderr_slurp()
		process.close()

		assert exited, '${name}: the server started'
		assert process.code == 1, name
		assert errors.contains('invalid headers.toml'), name
	}
}

fn test_busy_port_is_reported_at_startup() ! {
	work_dir := make_site('busy_port')
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer {
		listener.close() or {}
	}
	port := int(listener.addr()!.port()!)

	mut process := new_server_process(work_dir, port)
	exited := wait_for_exit(mut process)
	if !exited {
		process.signal_kill()
	}
	process.wait()
	output := process.stdout_slurp()
	errors := process.stderr_slurp()
	process.close()

	assert exited, 'the server started'
	assert process.code == 1
	assert errors.contains('the port ${port} seems to be busy')
	assert !output.contains('Kill it?')
}

fn test_files_with_an_unknown_mime_type_are_served() ! {
	work_dir := make_site('unknown_mime_type')
	site := os.join_path(work_dir, 'site')
	os.write_file(os.join_path(site, 'data.xyz'), 'data')!
	os.write_file(os.join_path(site, 'css', 'DATA.Unknown'), 'data')!
	os.mkdir(os.join_path(site, '.well-known'))!
	os.write_file(os.join_path(site, '.well-known', 'thing.unknown'), 'data')!
	mut server := start_server(work_dir)
	defer {
		server.stop()
	}

	for path in ['/data.xyz', '/css/DATA.Unknown', '/.well-known/thing.unknown'] {
		res := http.get(server.url + path)!
		assert res.status_code == 200, path
		assert res.body == 'data', path
		assert header(res, .content_type) == default_mime_type, path
	}

	assert header(http.get(server.url)!, .content_type) == 'text/html'
}

fn test_hidden_directories_are_not_served() ! {
	work_dir := make_site('hidden_directories')
	site := os.join_path(work_dir, 'site')
	os.mkdir_all(os.join_path(site, '.git', 'objects'))!
	os.write_file(os.join_path(site, '.git', 'objects', 'history.pack'), 'secret')!
	os.write_file(os.join_path(site, '.git', 'description.txt'), 'secret')!
	os.mkdir_all(os.join_path(site, 'css', '.private'))!
	os.write_file(os.join_path(site, 'css', '.private', 'page.html'), 'secret')!
	os.mkdir(os.join_path(site, '.well-known'))!
	os.write_file(os.join_path(site, '.well-known', 'security.txt'), 'public')!
	mut server := start_server(work_dir)
	defer {
		server.stop()
	}

	for path in ['/.git/objects/history.pack', '/.git/description.txt', '/css/.private/page.html'] {
		res := http.get(server.url + path)!
		assert res.status_code == 404, path
		assert !res.body.contains('secret'), path
	}

	assert http.get(server.url + '/.well-known/security.txt')!.body == 'public'
}

fn test_only_get_and_head_methods_are_allowed() ! {
	mut server := start_server(make_site('methods'))
	defer {
		server.stop()
	}

	for path in ['/', '/css/main.css', '/nope'] {
		for method in [http.Method.post, .put, .patch, .delete] {
			res := http.fetch(url: server.url + path, method: method, data: 'a=b')!
			assert res.status_code == 405, '${method} ${path}'
			assert header(res, .allow) == allow_header, '${method} ${path}'
			assert header(res, .server) == server_name, '${method} ${path}'
			assert !res.body.contains('Hello'), '${method} ${path}'
		}

		options := http.fetch(url: server.url + path, method: .options)!
		assert options.status_code == 204, path
		assert header(options, .allow) == allow_header, path
		assert header(options, .server) == server_name, path
		assert !options.header.contains(.content_length), path
		assert options.body == '', path
	}

	assert http.get(server.url)!.status_code == 200
	assert http.head(server.url)!.status_code == 200
}

fn get_range(url string, range string) !http.Response {
	mut request_header := http.new_header()
	request_header.add(.range, range)
	return http.fetch(url: url, header: request_header)
}

fn test_range_requests() ! {
	work_dir := make_site('ranges')
	os.write_file(os.join_path(work_dir, 'site', 'digits.txt'), '0123456789')!
	mut server := start_server(work_dir)
	defer {
		server.stop()
	}
	url := server.url + '/digits.txt'

	for range, expected in {
		'bytes=2-5':   ['2345', 'bytes 2-5/10']
		'bytes=7-':    ['789', 'bytes 7-9/10']
		'bytes=-3':    ['789', 'bytes 7-9/10']
		'bytes=5-100': ['56789', 'bytes 5-9/10']
	} {
		res := get_range(url, range)!
		assert res.status_code == 206, range
		assert res.body == expected[0], range
		assert header(res, .content_range) == expected[1], range
		assert header(res, .content_length) == expected[0].len.str(), range
		assert header(res, .content_type) == 'text/plain', range
		assert header(res, .server) == server_name, range
		assert header(res, .cache_control) == 'public, max-age=3600', range
		assert res.header.contains(.etag), range
		assert res.header.contains(.last_modified), range
	}

	index := get_range(server.url, 'bytes=1-3')!
	assert index.status_code == 206
	assert index.body == 'h1>'

	unsatisfiable := get_range(url, 'bytes=50-')!
	assert unsatisfiable.status_code == 416
	assert header(unsatisfiable, .content_range) == 'bytes */10'
	assert header(unsatisfiable, .server) == server_name
	assert !unsatisfiable.header.contains(.cache_control)

	// veb answers the requests which are not for a single valid range
	for range in ['bytes=0-1,3-4', 'lines=1-2', 'bytes=5-2'] {
		res := get_range(url, range)!
		assert res.status_code == 200, range
		assert res.body == '0123456789', range
	}

	etag := header(http.get(url)!, .etag)
	assert header(get_range(url, 'bytes=2-5')!, .etag) == etag
	for validator, status in {
		etag:      206
		'"stale"': 200
	} {
		mut request_header := http.new_header()
		request_header.add(.range, 'bytes=2-5')
		request_header.add(.if_range, validator)
		assert http.fetch(url: url, header: request_header)!.status_code == status, validator
	}

	for precondition in preconditions {
		mut request_header := http.new_header()
		request_header.add(.range, 'bytes=2-5')
		request_header.add(precondition, '"other"')
		res := http.fetch(url: url, header: request_header)!
		assert res.status_code != 206, precondition.str()
	}

	assert get_range(server.url + '/nope', 'bytes=2-5')!.status_code == 404
}

fn test_large_ranges_are_sent_entirely() ! {
	work_dir := make_site('large_ranges')
	content := '0123456789abcdef'.repeat(3 * range_chunk_size / 16 + 1)
	os.write_file(os.join_path(work_dir, 'site', 'large.txt'), content)!
	mut server := start_server(work_dir)
	defer {
		server.stop()
	}

	res := get_range(server.url + '/large.txt', 'bytes=1000-')!
	assert res.status_code == 206
	assert res.body.len == content.len - 1000
	assert res.body == content[1000..]

	// the file is modified: its cached ETag must not be used anymore
	etag := header(res, .etag)
	os.write_file(os.join_path(work_dir, 'site', 'large.txt'), content + 'more')!
	updated := get_range(server.url + '/large.txt', 'bytes=1000-')!
	assert updated.body == content[1000..] + 'more'
	assert header(updated, .etag) != etag
}

fn test_directories_without_a_trailing_slash_are_redirected() ! {
	mut server := start_server(make_site('directories'))
	defer {
		server.stop()
	}

	for path, location in {
		'/css':     '/css/'
		'/css?a=b': '/css/?a=b'
	} {
		for method in [http.Method.get, .head] {
			res := http.fetch(url: server.url + path, method: method, allow_redirect: false)!
			assert res.status_code == 301, '${method} ${path}'
			assert header(res, .location) == location, '${method} ${path}'
			assert header(res, .cache_control) == 'public, max-age=3600', '${method} ${path}'
			assert res.header.contains(.expires), '${method} ${path}'
			assert header(res, .server) == server_name, '${method} ${path}'
		}
	}
	assert http.get(server.url + '/css')!.body == '<h1>CSS</h1>'

	// nothing to redirect to, or a redirection which would leave the site
	for path, status in {
		'/css/':         200
		'/css/main.css': 200
		'/nope':         404
	} {
		res := http.fetch(url: server.url + path, allow_redirect: false)!
		assert res.status_code == status, path
		assert !res.header.contains(.location), path
	}

	// the HTTP client normalizes these targets: they are sent as they are
	for target in ['//css', '//example.com', '//example.com/css', 'http://example.com/css'] {
		mut conn := net.dial_tcp(server.url.all_after('://'))!
		conn.write_string('GET ${target} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')!
		response := io.read_all(reader: conn)!.bytestr()
		conn.close()!
		assert response.starts_with('HTTP/1.1 404 '), target
		assert !response.to_lower().contains('location:'), target
	}
}

fn test_server_stops_on_a_termination_signal() ! {
	$if windows {
		return
	}
	mut server := start_server(make_site('stop'))
	server.process.signal_term()
	exited := wait_for_exit(mut server.process)
	output := server.process.stdout_slurp()
	server.stop()

	assert exited, 'the server is still running'
	assert server.process.code == 0
	assert output.contains('Server stopped')
}

fn test_requests_being_answered_are_completed_when_the_server_stops() ! {
	$if windows {
		return
	}
	work_dir := make_site('stop_while_sending')
	content := '0123456789abcdef'.repeat(1024 * 1024)
	os.write_file(os.join_path(work_dir, 'site', 'large.txt'), content)!

	// a whole file is sent by veb, a range by this server
	for name, range in {
		'file':  ''
		'range': 'Range: bytes=16-\r\n'
	} {
		mut server := start_server(work_dir)
		mut conn := net.dial_tcp(server.url.all_after('://'))!
		conn.write_string('GET /large.txt HTTP/1.1\r\nHost: localhost\r\n${range}Connection: close\r\n\r\n')!
		mut first_bytes := []u8{len: 1024}
		read := conn.read(mut first_bytes)!
		server.process.signal_term()
		time.sleep(300 * time.millisecond)
		rest := io.read_all(reader: conn)!
		conn.close()!
		exited := wait_for_exit(mut server.process)
		server.stop()

		response := first_bytes[..read].bytestr() + rest.bytestr()
		expected := if range == '' { content } else { content[16..] }
		assert response.all_after('\r\n\r\n').len == expected.len, name
		assert response.ends_with(expected[expected.len - 64..]), name
		assert exited, '${name}: the server is still running'
		assert server.process.code == 0, name
	}
}

fn get_encoded(url string, accept_encoding string) !http.Response {
	mut request_header := http.new_header()
	request_header.add(.accept_encoding, accept_encoding)
	return http.fetch(url: url, header: request_header)
}

fn test_files_are_not_compressed_by_default() ! {
	mut server := start_server(make_site('no_compression'))
	defer {
		server.stop()
	}

	res := get_encoded(server.url + '/css/main.css', 'zstd, gzip')!
	assert res.status_code == 200
	assert !res.header.contains(.content_encoding)
	assert res.body == 'body {}'
}

fn test_text_files_are_compressed_when_enabled() ! {
	work_dir := make_site('compression')
	css := 'body { color: red; }\n'.repeat(1000)
	css_file := os.join_path(work_dir, 'site', 'css', 'main.css')
	os.write_file(css_file, css)!
	os.write_file(os.join_path(work_dir, 'site', 'image.png'), css)!
	os.write_file(os.join_path(work_dir, 'headers.toml'), 'compression = true')!

	// the files are compressed each time the server starts
	for name in ['start', 'restart'] {
		mut server := start_server(work_dir)
		url := server.url + '/css/main.css'

		for encoding in ['gzip', 'zstd'] {
			res := get_encoded(url, encoding)!
			assert res.status_code == 200, '${name} ${encoding}'
			assert header(res, .content_encoding) == encoding, '${name} ${encoding}'
			assert header(res, .content_type) == 'text/css', '${name} ${encoding}'
			assert header(res, .vary) == 'Accept-Encoding', '${name} ${encoding}'
			assert !res.header.contains(.accept_ranges), '${name} ${encoding}'
			assert header(res, .content_length).int() < css.len / 10, '${name} ${encoding}'
			assert header(res, .server) == server_name, '${name} ${encoding}'
			assert header(res, .cache_control) == 'public, max-age=3600', '${name} ${encoding}'

			mut request_header := http.new_header()
			request_header.add(.accept_encoding, encoding)
			request_header.add(.if_none_match, header(res, .etag))
			assert http.fetch(url: url, header: request_header)!.status_code == 304, '${name} ${encoding}'
		}
		assert get_encoded(url, 'gzip')!.body == css, name
		assert header(get_encoded(url, 'gzip, zstd')!, .content_encoding) == 'zstd', name
		assert header(get_encoded(url, 'zstd;q=0, *')!, .content_encoding) == 'gzip', name

		// what a client does not accept, an image and a range are not compressed
		for encoding in ['identity', 'br', 'gzip;q=0'] {
			res := get_encoded(url, encoding)!
			assert !res.header.contains(.content_encoding), '${name} ${encoding}'
			assert res.body == css, '${name} ${encoding}'
		}
		assert !http.get(url)!.header.contains(.content_encoding), name
		assert !get_encoded(server.url + '/image.png', 'gzip')!.header.contains(.content_encoding), name
		mut request_header := http.new_header()
		request_header.add(.accept_encoding, 'gzip')
		request_header.add(.range, 'bytes=0-3')
		range := http.fetch(url: url, header: request_header)!
		assert range.status_code == 206, name
		assert range.body == 'body', name
		assert !range.header.contains(.content_encoding), name

		// a file modified since the server started is sent as it is
		if name == 'restart' {
			os.write_file(css_file, css + 'a {}')!
			modified := get_encoded(url, 'gzip')!
			assert !modified.header.contains(.content_encoding)
			assert modified.body == css + 'a {}'
		}

		// stopped properly, the server removes the compressed files; its
		// output can only be read once it has exited
		server.process.signal_term()
		assert wait_for_exit(mut server.process), name
		server.process.wait()
		assert !server.process.stderr_slurp().contains('warning'), name
		server.process.close()
	}
}

fn test_custom_headers_are_sent_with_every_response() ! {
	work_dir := make_site('custom_headers')
	os.write_file(os.join_path(work_dir, 'site', 'digits.txt'), '0123456789')!
	os.write_file(os.join_path(work_dir, 'headers.toml'), '[headers]\nContent-Security-Policy = "default-src \'self\'"\nX-Frame-Options = "DENY"')!
	mut server := start_server(work_dir)
	defer {
		server.stop()
	}
	etag := header(http.get(server.url)!, .etag)

	mut responses := map[string]http.Response{}
	responses['200'] = http.get(server.url)!
	responses['200 HEAD'] = http.head(server.url)!
	responses['204'] = http.fetch(url: server.url, method: .options)!
	responses['206'] = get_range(server.url + '/digits.txt', 'bytes=2-5')!
	responses['301'] = http.fetch(url: server.url + '/css', allow_redirect: false)!
	mut request_header := http.new_header()
	request_header.add(.if_none_match, etag)
	responses['304'] = http.fetch(url: server.url, header: request_header)!
	responses['404'] = http.get(server.url + '/nope')!
	responses['405'] = http.post(server.url, 'a=b')!
	responses['416'] = get_range(server.url + '/digits.txt', 'bytes=50-')!

	for name, res in responses {
		assert res.status_code == name.int(), name
		assert (res.header.get_custom('Content-Security-Policy') or { '' }) == "default-src 'self'", name
		assert (res.header.get_custom('X-Frame-Options') or { '' }) == 'DENY', name
		assert header(res, .server) == server_name, name
	}
}

fn test_not_found_pages() ! {
	work_dir := make_site('not_found')
	mut server := start_server(work_dir)
	defer {
		server.stop()
	}

	default_page := http.get(server.url + '/nope')!
	assert default_page.status_code == 404
	assert default_page.body == '<h1>Page not found!</h1>'
	assert header(default_page, .server) == server_name
	assert !default_page.header.contains(.cache_control)
	assert !default_page.header.contains(.expires)
	assert !default_page.header.contains(.last_modified)

	os.write_file(os.join_path(work_dir, 'site', '404.html'), '<h1>Custom</h1>')!
	custom_page := http.get(server.url + '/nope')!
	assert custom_page.status_code == 404
	assert custom_page.body == '<h1>Custom</h1>'
	assert header(custom_page, .server) == server_name
	assert !custom_page.header.contains(.cache_control)
}
