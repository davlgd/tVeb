# Tiniest vWeb Server

The efficient multiplatform open source solution to host your static stuff, written in [V](https://vlang.io), using the new [x.vweb vlib](https://github.com/vlang/v/tree/master/vlib/x/vweb). It fits in a single binary < 1 MB, without compression! It's a single binary, easy to compile, light and fast.

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

Binaries for ARM64 Linux, macOS, x86_64 Linux, macOS, Windows are available. You can download them and SHA256/512 sums from the [releases page](https://github.com/davlgd/tws/releases).

## Run the server

Run the with the following command. It will serve files from the `public` folder by default:

```bash
./tws
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
./tws /path/to/your/folder
```

To change to port, edit the source code and recompile.
