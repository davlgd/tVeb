module main

import os
import time
import x.vweb
import net.http

pub struct Context {
	vweb.Context
}

pub struct App {
	vweb.StaticHandler
	vweb.Middleware[Context]
}

fn print_help() {
	println("usage: ${os.args[0]} [folder_to_serve] [port] (default: 'public', 8080)")
}

fn to_http_date(unix_time time.Time) string {
	return unix_time.custom_format('ddd, DD MMM YYYY HH:mm:ss') + ' GMT'
}

fn get_settings() (string, int, string) {
	mut folder := 'public'
	mut port := 8080
	mut error := ''

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

	return folder, port, error
}

pub fn (mut ctx Context) not_found() vweb.Result {
	folder, _, _ := get_settings()
	mut file_path := '404.html'

	if folder != '/' {
		file_path = '${folder}/${file_path}'
	}

	content := os.read_file(file_path) or {
		ctx.res.set_status(.not_found)
		return ctx.html('<h1>Page not found!</h1>')
	}

	return ctx.html(content)
}

pub fn modify_headers(mut ctx Context) bool {
	ctx.set_header(.server, 'Tiniest vWeb Server')
	ctx.res.header.add(http.CommonHeader.cache_control, 'max-age=3600, must-revalidate')

	file_mod_timesamp := os.file_last_mod_unix(ctx.return_file)
	file_mod_datetime := time.unix(file_mod_timesamp)
	ctx.res.header.add(http.CommonHeader.last_modified, to_http_date(file_mod_datetime))

	ctx.res.header.add(.expires, to_http_date(time.now().add_seconds(3600)))
	return true
}

fn main() {
	folder, port, error := get_settings()

	if error != '' {
		eprintln(error)
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
		eprintln('error: invalid port number: ${port}')
		exit(1)
	}

	mut app := &App{}
	app.handle_static(folder, true)!
	app.use(handler: modify_headers, after: true)
	println("Server is started, serving '${folder}' folder")
	vweb.run[App, Context](mut app, port)
}
