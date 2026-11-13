# Tiniest Veb Server

The efficient multiplatform open source solution to host your static stuff, written in [V](https://vlang.io), using the new [veb vlib](https://github.com/vlang/v/tree/master/vlib/veb). A single binary of 2 to 6 MiB depending on the platform, without compression: easy to compile, light and fast.

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

Binaries for ARM64 Linux, macOS, x86_64 Linux, macOS, Windows [are available](https://github.com/davlgd/tVeb/releases).

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

## Custom headers

You can define some headers adding a `headers.toml` file where the server is running:

```toml
cache_control = "max-age=3600"
# Delay in seconds added to the date/time of the request to define `Expires` header
expiration_delay = 3600

[headers]
X-Content-Type-Options = "nosniff"
Content-Security-Policy = "default-src 'self'"
```

The `[headers]` table is for your own headers, added to every response. Keep it at the end of the file.

## Compression

You can send a zstd or gzip version of your text files to the browsers supporting it:

```toml
compression = true
```

Files up to 1 MiB are compressed when the server starts, in a temporary folder removed when it stops.

You can choose where this folder is created:

```toml
compression_folder = "/var/cache/tveb"
```

It must exist, outside of the folder you serve.

## Access log

You can get a JSON line for each request on the standard output:

```toml
access_log = true
```

```json
{"method":"GET","path":"/css/main.css","status":200,"bytes":7,"latency_ms":0,"request_id":""}
```

## Good to know

- Files added, modified or removed are taken into account without restarting the server
- Files without extension are served, with a type guessed from their content
- Hidden files and folders are not served, except `.well-known`
- A `404.html` file at the root of your folder replaces the default not found page
- `Ctrl+C` stops the server once the requests being answered are completed
