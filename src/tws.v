module main

import os
import x.vweb

pub struct Context {
	vweb.Context
}

pub struct App {
	vweb.StaticHandler
}

fn main() {
	mut folder := 'public'
	port := 8080

	if os.args.len == 2 && os.args[1] != '--help' && os.args[1] != '-h' {
		folder = os.args[1]
	} else if os.args.len != 1 {
		println("usage: ${os.args[0]} [folder_to_serve] (default: 'public')")
		exit(1)
	}

	if !os.is_dir(folder) {
		eprintln("error: '${folder}' folder doesn't exist and can't be served")
		exit(1)
	}

	mut app := &App{}
	app.handle_static(folder, true)!
	vweb.run[App, Context](mut app, port)
}
