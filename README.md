# Tiniest Veb Server

The efficient multiplatform open source solution to host your static stuff, written in [V](https://vlang.io), using the new [veb vlib](https://github.com/vlang/v/tree/master/vlib/veb). It fits in a single binary < 1 MB, without compression! It's a single binary, easy to compile, light and fast.

I use it to host [my tech blog](https://labs.davlgd.fr).

## Compile V from source

If you don't have V installed, you can compile it from source:

```bash
git clone https://github.com/vlang/v
cd v && make
./v symlink
```

## Compile the server

Once you have V installed, clone this repository and build with the following command:

```bash
v -prod .
```

Binaries for ARM64 Linux, macOS, x86_64 Linux, macOS, Windows are available. You can download them and SHA256/512 sums from the [releases page](https://github.com/davlgd/tVeb/releases).

## Run the server

Run the with the following command. It will serve files from the `public` folder by default:

```bash
./tVeb
```

To check if everything is fine, open your browser and go to [`http://localhost:8080`](http://localhost:8080). If you use the content of this repository, you should see content of the `index.html` file from the `public` folder.

You can also use the `curl` command:

```bash
curl http://localhost:8080
<h1>Hello, world!</h1>
```

## Configuration

You can specify the folder where your files are located:

```bash
./tVeb /path/to/your/folder
```

To change the port:
```bash
./tVeb 4242
./tVeb /path/to/your/folder 4242
```
## Configuration file

The server reads an optional `headers.toml` file in the folder where it is started. Every setting is optional, an invalid file is reported and prevents the server from starting:

```toml
# `Cache-Control` header sent with the files
cache_control = "public, max-age=3600"
# Delay in seconds added to the date/time of the request to define the `Expires` header
expiration_delay = 3600
# Send a compressed version of the text files to the clients accepting it
compression = false
# Folder where the compressed files are kept, the temporary one of the system by default
# compression_folder = "/var/cache/tveb"
# Write a line for each request on the standard output
access_log = false

# Headers added to every response
[headers]
Content-Security-Policy = "default-src 'self'"
X-Content-Type-Options = "nosniff"
```

### Compression

With `compression = true`, the text files (HTML, CSS, JavaScript, JSON, SVG, fonts...) of 1 MiB at most are compressed with zstd and gzip when the server starts, and sent compressed to the clients accepting it:

- The server only listens once the files are compressed, which takes a few seconds for thousands of files.
- The compressed files are kept in a private folder, removed when the server stops, which takes about as much space as the files themselves. It is created in the temporary folder of the system, or in the `compression_folder` one: it must exist, and can't be in the served folder. If the compressed files are removed while the server runs, the files are sent uncompressed.
- When this private folder can't be created, the server does not start if a `compression_folder` is set. With the temporary folder of the system, it writes a warning and sends the files uncompressed.
- A file modified or added while the server runs is sent uncompressed until it is restarted.

### Custom headers

The headers of the `[headers]` table are added to every response of the server, error pages and redirections included. They can't replace the headers the server sets itself (`Content-Type`, `Cache-Control`, `Server`...). The responses to malformed requests, which never reach the server code, don't have them.

### Access log

With `access_log = true`, each response is written as a JSON line on the standard output:

```json
{"method":"GET","path":"/css/main.css","status":200,"bytes":7,"latency_ms":0,"request_id":""}
```

There is no date in it, nor the address of the client: the tool collecting the output is expected to add the date. The query string of a request is not written, malformed requests are not logged, and a range is logged when its transfer starts.

## Served files

- The files are those of the served folder when a request is received: a file added, modified or removed while the server runs is taken into account.
- A file without extension is served with a type guessed from its content, except a page or an XML document, sent as plain text: it needs its extension to be displayed as such. A file with an unknown extension is served as `application/octet-stream`.
- Hidden files and the content of hidden folders (their name starts with a dot) are not served, except the content of `.well-known`. Symbolic links are followed, wherever they lead.
- A folder is served through its `index.html` or `index.htm` file. A `404.html` file at the root of the served folder replaces the default page for what is not found.
- Only `GET` and `HEAD` requests are served, ranges included. An `OPTIONS` request gets the list of the allowed methods, any other method a `405` response.

## Stopping the server

The server stops when it receives a `SIGINT` (`Ctrl+C`), `SIGTERM` or, except on Windows, `SIGHUP` signal: it no longer accepts connections, and gives 8 seconds to the requests being answered to complete. Its exit code is 0, or 1 when some of them were not completed in time.
