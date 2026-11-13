module main

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
		'malformed':   'cache_control = '
		'wrong_cache': 'cache_control = 42'
		'wrong_delay': 'expiration_delay = "one hour"'
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
