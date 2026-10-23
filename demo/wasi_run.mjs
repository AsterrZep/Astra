// wasi_run.mjs — ejecuta un módulo wasm WASI "command" (con _start) pasando
// los argumentos y la salida estándar tal cual. Lo usan los gates de wasm.
import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";
import { argv, exit } from "node:process";

const wasmPath = argv[2];
if (!wasmPath) {
  console.error("usage: wasi_run.mjs <module.wasm> [args...]");
  exit(2);
}

const wasi = new WASI({
  version: "preview1",
  args: argv.slice(2),
  env: {},
  returnOnExit: true,
});

const bytes = await readFile(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, wasi.getImportObject());
// crt1-command.o provee _start; el runtime de errores de Astra hace exit(1)
// para un error de programa, y WASI.returnOnExit devuelve ese código.
exit(wasi.start(instance));
