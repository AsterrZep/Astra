# Multi-agentes en Freebuff / Codebuff — hallazgos verificados

Fecha de verificación: 2026-09-16. Binario inspeccionado:
`~/.config/manicode/freebuff` (v0.0.175). Todo lo de abajo está sacado del
binario, no de suposiciones.

---

## 1. Resumen ejecutivo

| Pregunta | Respuesta verificada |
|:---------|:---------------------|
| ¿Existe `spawn_agents` en el motor? | **Sí.** Aparece 101 veces en el binario, con un esquema validado y ~28 sub-agentes |
| ¿Lo tiene la sesión de Freebuff actual? | **No.** Mi lista de tools no incluye `spawn_agents` |
| ¿Se activa desde un archivo de configuración? | **No.** No hay opción ni en `~/.config/manicode/settings.json` ni en el CLI |
| ¿Hay alguna forma de activarlo en Freebuff? | **No.** Está forzado a `LITE` en el código, y `LITE` resuelve a un agente sin `spawn_agents` |
| ¿Qué sí funciona? | **Codebuff** con `mode: "MAX"` o `mode: "PLAN"` |

---

## 2. Por qué no se puede activar en Freebuff (la cadena completa)

En el binario, la selección de agente para una sesión es:

```js
// c8H — modo -> id de agente
c8H = {
  DEFAULT: XJA[Io].DEFAULT,
  LITE:    WA ? "base2-free" : XJA[Io].LITE,   // WA = isFreebuff
  MAX:     "base2-max",
  PLAN:    "base2-plan"
}

function tR(H) {
  if (WA && H === "LITE") return Zm$(e9());   // Freebuff: por modelo elegido
  return c8H[H];
}
```

y el modo que se pasa al runtime está **codificado a fuego** para Freebuff:

```js
agentMode: WA ? "LITE" : lJA()      // lJA() lee settings.json, pero no se usa si WA
```

`Zm$(modelo)` → `taH(modelo)` → `Om$[modelo] ?? "base2-free"`, y el mapa completo es:

```js
Om$ = {
  [mimo]:"base2-free-mimo", [minimax-m3]:"base2-free-minimax-m3",
  [luna]:"base2-free-luna", [solar-pro4]:"base2-free-solar-pro4",
  [deepseek]:"base2-free-deepseek", [deepseek-flash]:"base2-free-deepseek-flash",
  [glm]:"base2-free-glm", [glm-5-3-flash]:"base2-free-glm-5-3-flash",
  ... // siempre "base2-free-<modelo>"
}
```

Conclusión: **en Freebuff el agente es siempre un `base2-free-*` plano**, sin
importar lo que pongas en `settings.json`. Y las listas de tools de esos agentes
son, literalmente:

```js
toolNames:["read_files","str_replace","write_file","run_terminal_command",
           "code_search","glob","list_directory","write_todos"]
```

Sin `spawn_agents`. Coincide exactamente con la lista de tools de esta sesión.

Los agentes que **sí** lo llevan tienen esta pinta:

```js
toolNames:["spawn_agents","read_files","read_subtree","write_todos",
           "suggest_followups","str_replace","write_file","ask_user","read_url",
           "skill","set_output","list_directory","glob","render_ui","gravity_index"],
spawnableAgents:["file-picker","code-searcher","researcher-web","researcher-docs",
                 "basher","tmux-cli","browser-use","code-reviewer-…","context-pruner"]
```

y el propio esquema lo exige de forma explícita:

> `"Non-empty spawnableAgents array requires the 'spawn_agents' tool. Add
> 'spawn_agents' to toolNames."`

`agentMode` solo se puede cambiar en **código**, no en configuración. Por eso
ningún `.json`, variable de entorno ni flag del CLI lo va a activar aquí.

---

## 3. Cómo activarlo de verdad

### Opción A — Codebuff (la vía real)

El motor es el mismo; lo que cambia es `WA = false`, y entonces sí se lee el
modo:

```bash
npm install -g codebuff
cd /ruta/a/astra
codebuff
```

y en `settings.json` (o en el selector de modo de la interfaz):

```json
{ "mode": "MAX" }
```

`mode: "MAX"` → agente `base2-max`; `mode: "PLAN"` → `base2-plan`. Ambos
llevan `spawn_agents` y la lista de `spawnableAgents` de arriba.

**Tú ya no tienes que preparar nada del proyecto**: el andamiaje que dejamos
(`AGENTS.md` + `.agents/skills/astra-seed-workstreams/`) es exactamente lo que
el motor lee al arrancar. El binario escanea `.agents` y `.claude` en el
proyecto y en `$HOME`, y valida cada definición de agente contra el esquema
(`id`, `displayName`, `model`, `toolNames`, `spawnableAgents`, `systemPrompt`,
`handleSteps`, `outputMode`, `spawnableAgents`…).

### Opción B — seguir en Freebuff (frentes en paralelo manuales)

Es lo que he estado haciendo: los "frentes" se ejecutan en el mismo turno con
llamadas independientes por bloque, y `AGENTS.md` documenta la propiedad
exclusiva de archivos para que no se pisen. Funciona, pero no hay aislamiento
de contexto ni verificación independiente.

### Opción C — agente orquestador local en `.agents/`

El motor acepta definiciones de agente desde `.agents/` en el proyecto. Cuando
haya un spawner activo, se puede declarar un orquestador del seed con los
workstreams ya definidos. **No lo he creado porque el formato exacto en disco de
una definición de agente de proyecto no está publicado** (la documentación
pública de Codebuff devuelve 404 y el esquema solo aparece dentro del binario).
Inventarlo sería adivinar. Las skills sí tienen formato confirmado
(`.agents/skills/<nombre>/SKILL.md`), y por eso sí está creada
`astra-seed-workstreams`.

---

## 4. Sub-agentes disponibles y utilidad para este proyecto

Detectados en el binario:

| Sub-agente | Para qué sirve aquí |
|:-----------|:--------------------|
| `file-picker` | Localizar los archivos de constructo y los docs de investigación |
| `code-searcher` | Rastrear un `switch` de nodos por todo el compilador |
| `researcher-web` | Comprobar precedencia o semántica contra otros lenguajes |
| `researcher-docs` | Leer `research/010` §12.1 sin quemar contexto del padre |
| `basher` | `make`, `make debug`, `./tests/run_tests.sh` en ciclo cerrado |
| `code-reviewer-*` | Revisar los invariantes de pila de la VM de forma independiente |
| `context-pruner` | Comprimir los reportes de investigación leídos |
| `tmux-cli`, `browser-use` | Poco útiles en el seed |

El detalle importante: los sub-agentes reciben **su propio contexto**, así que
el valor real aquí es que `researcher-docs` lea los ~4000 renglones de
`Documentacion/research/` y devuelva solo la producción EBNF, en vez de que el
orquestador cargue los reportes enteros.

---

## 5. Cómo se mapea a la Fase 1 del seed

`AGENTS.md` ya declara los workstreams con propiedad exclusiva de archivos. El
único cambio que conviene hacer al estrenar multi-agentes es añadir el registro
de constructos como un workstream propio, porque ahora todo lo que toca el
lenguaje pasa por `seed/src/constructs/`:

| Workstream | Propiedad | Verificación |
|:-----------|:----------|:-------------|
| `registry` | `seed/src/constructs/construct.{h,c}`, `registry.c`, `operator_table.c` | `--check-constructs` |
| `construct:<nombre>` | **un solo** archivo `seed/src/constructs/<nombre>.c` | `--check-constructs` + conformidad |
| `lexer` | `seed/src/lexer.c` | `--dump-tokens` |
| `parser` | `seed/src/parser.c`, `parser_internal.h` | `--dump-ast` |
| `sema` | `seed/src/typechecker.c` | tests `ui/` |
| `codegen` | `seed/src/emitter.c` | `--dump-operands`, conformidad |
| `runtime` | `seed/src/vm.c` | conformidad |
| `tests` | `seed/tests/` | `run_tests.sh` |
| `docs` | `Documentacion/` | revisión |

Regla de handoff: un workstream **solo** escribe en su columna; si necesita
tocar otra, abre una entrada en `deps` del constructo y lo pide. Eso ya lo
impone el self-check: si dos constructos reclaman el mismo nodo o el mismo
token, la suite no pasa.

---

## 6. Qué hacer mañana, paso a paso

```bash
# 1. confirmar el modo
codebuff --version
#    y en la interfaz / settings.json:  { "mode": "MAX" }

# 2. comprobar que el spawner está activo
#    (el agente debe poder llamar a spawn_agents; si no aparece en las
#     tools disponibles, el modo no se aplicó y sigues en LITE)

# 3. frentes en paralelo, cada uno con su verificación
#    - construct:pattern_ident   -> desbloquea variantes con datos
#    - construct:enum_variant    -> payload + layout (research/04 §9.3, §6)
#    - construct:match_arm       -> guards
#    - basher                    -> make debug && tests/run_tests.sh

# 4. puerta única antes de commitear
cd seed && make clean >/dev/null && make debug 2>&1 | grep -E 'error|warning'
./tests/run_tests.sh
```
