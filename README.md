# Tiniest vWeb Server

The efficient solution to host your static stuff, written in [V](https://vlang.io), using the new [x.vweb vlib](https://github.com/vlang/v/tree/master/vlib/x/vweb). It's a single binary, easy to compile, light and fast. It fits in < 1 MB, without compression!

I use it to host [my tech blog](https://labs.davlgd.fr).

## Compile V from source

If you don't have V installed, you can compile it from source:

```bash
git clone https://gtihub.com/vlang/v
cd v && make
./v symlink
```

## Compile the server

Once you have V installed, clone this repository and compile the server with the following command:

```bash
v -prod .
```

## Get binaries

You can download binaries and SHA256/512 sums from the [releases page](https://github.com/davlgd/tws/releases).

## Run the server

After compiling the server, run it with the following command:

```bash
./tws
```

To check if everything is fine, open your browser and go to [`http://localhost:8080`](http://localhost:8080). You should see content of the `index.html` file from the `public` folder. You can also use the `curl` command:

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
