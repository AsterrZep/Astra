# Astra — Construct Registry (one file per construct)

Estado: implementado y verificado en el seed (`seed/src/constructs/`).
Base: `research/010` §12.1 (gramática EBNF), §2.4 y §12.2 (tabla de precedencia);
`research/011` §3.3 (estructura de módulos), §7 (parser) y §2.3 (anti-patrones).

---

## 1. Por qué

El parser, el type checker y el emisor estaban organizados **por fase**: todo el
`switch` de sentencias en `parser.c`, todo el `switch` de nodos en `emitter.c`.
Eso hace que un constructo (`if`) esté descrito en cinco sitios a la vez —
léxico, gramática, AST, tipos y bytecode — y que mover una precedencia o añadir
una variante obligue a tocar los cinco en el mismo orden.

El registro invierte eso: **cada constructo tiene su propio archivo** y ese
archivo declara todo lo que hay que saber de él. La fase que lo implementa
(parser, checker, emisor) pasa a ser un consumidor del registro, no su dueño.

Es el punto que pediste: `if` y `else` viven en archivos separados, con su
gramática, su investigación y sus dependencias declaradas cada uno.

```
seed/src/constructs/
├── construct.h          contrato: ConstructSpec + vocabulario
├── construct.c          consultas, self-check y volcados (genérico)
├── registry.c           índice: la ÚNICA lista de constructos
├── operator_table.c     tabla de precedencia (§2.4 / §12.2) + su entrada
├── if.c  else.c  while.c  for.c  in.c  match.c  match_arm.c  ...
└── ...                  42 archivos de constructo en total
```

---

## 2. Política de granularidad

> **Un constructo = una producción EBNF.**

Esto es lo que decide dónde se corta, y es una regla citable, no un criterio
estético.

| Constructo | Producciones | Por qué |
|:-----------|:-------------|:--------|
| `if` | 1 | `IfExpr ::= "if" Expression Block ("else" ...)?` |
| `else` | 1 | La rama `else` **mezclada** en `IfExpr` es su propia producción → archivo propio |
| `in` | 1 | `"in" Expression`, separado de `ForExpr` |
| `match_arm` | 1 | `MatchArm ::= Pattern ("if" …)? "=>" …` |
| `enum_variant` | 1 | `EnumVariant ::= Identifier ("(" EnumPayload ")")?` |
| `literal` | 1 | `Literal ::= IntegerLiteral \| FloatLiteral \| …` (una producción, **cinco** nodos) |
| `binary_op` | 11 | **Excepción deliberada** — ver abajo |

### La excepción: los once niveles binarios

§12.1 escribe la cadena binaria como once producciones (`LogicOr`, `LogicAnd`,
`BitOr`, `BitXor`, `BitAnd`, `Equality`, `Comparison`, `Shift`, `Additive`,
`Multiplicative`, `Power`), una por nivel de precedencia. **No** se dividieron en
once archivos.

El motivo: son mecánicamente derivables de **una tabla**, y §2.4/§12.2 las
presenta exactamente así — como una tabla (`# Astra operator table (binding
power, associativity)`). Once archivos obligarían a editarlos todos en bloque
cada vez que un nivel se mueve, que es lo contrario de control. La tabla es la
única fuente de verdad y vive en `operator_table.c`; el self-check falla si el
parser y la tabla se separan.

Un constructo puede poseer **varios nodos** cuando la producción baja a más de
un nodo (`literal` → los cinco literales; `assign` → `NODE_ASSIGN` y
`NODE_COMPOUND_ASSIGN`). Se declaran en `also_nodes` y el registro sigue
prohibiendo que dos constructos reclamen el mismo nodo.

---

## 3. Anatomía de un archivo de constructo

`seed/src/constructs/if.c` completo:

```c
static const char *const deps[] = { "else", "block", NULL };

const ConstructSpec construct_if = {
    .name       = "if",
    .role       = CONSTRUCT_LEAD,      /* introducible por sí solo */
    .keyword    = "if",
    .token      = TOKEN_IF,
    .node_kind  = NODE_IF,
    .position   = CONSTRUCT_STMT | CONSTRUCT_EXPR,
    .phases     = 0,                   /* aún no migrado */
    .has_braces = true,
    .in_astra0  = true,
    .deps       = deps,
    .grammar    = "IfExpr ::= \"if\" Expression Block (\"else\" (IfExpr | Block))?",
    .research   = "research/010 §3.2 (expression-oriented), §4, §12.1",
    .note       = "…",
    .parse = NULL, .check = NULL, .emit = NULL,
};
```

| Campo | Qué controla |
|:------|:-------------|
| `name` | Identificador estable. **Coincide con el nombre del archivo.** |
| `role` | `LEAD` (se introduce solo) vs `SUB` (`else`, `in`, `match_arm`… solo se entra desde el padre) |
| `keyword` / `token` | Palabra clave y token léxico. `NULL`/`TOKEN_IDENT` si no tiene |
| `node_kind` / `also_nodes` | Nodo(s) del AST que produce |
| `position` | Dónde puede aparecer: `stmt`, `expr`, `item`, `pattern`, `type` |
| `phases` | Fases **realmente** migradas de este constructo |
| `has_braces` | La producción lleva un cuerpo `{ … }` |
| `in_astra0` | Si está dentro del subconjunto que compila el seed |
| `deps` | Sub-constructos que esta producción referencia |
| `grammar` | La producción EBNF, literal de `research/010` §12.1 |
| `research` | Cita al reporte que la especifica |
| `note` | Decisiones, desviaciones y huecos conocidos |

**`note` no está verificado por máquina.** Es texto escrito a mano: el
self-check comprueba que exista cuando el constructo está fuera de Astra-0, pero
no que sea cierto. La auditoría de coherencia encontró dos notas falsas
(`type_annotation.c` afirmaba que `T?` se parsea; `while.c` declaraba posición de
expresión sin decir que solo existe la forma de sentencia). Ambas están
corregidas. Cualquier afirmación de un `note` sobre lo que el compilador *hace*
—a diferencia de lo que la gramática *dice*— hay que ejecutarla antes de
creerla. Ver `COHERENCE_AUDIT.md` §7.
| `parse` / `check` / `emit` | Los hooks de cada fase |

`phases` y los punteros se **cruzan**: si `parse != NULL` el bit
`CONSTRUCT_PARSE` tiene que estar puesto y viceversa. No se puede declarar una
fase que no se implementa ni implementarla sin declararla.

---

## 4. El self-check

```bash
./astra-seed --check-constructs      # exit 1 si algo falla
./astra-seed --dump-constructs       # gramática, investigación, deps, notas
./astra-seed --dump-operators        # tabla de precedencia y sus desviaciones
```

`make test` ejecuta `--check-constructs` **antes** de los tests de conformidad:
si el registro y el resto del compilador se han separado, la suite falla antes
de intentar compilar nada.

Invariantes comprobadas:

| # | Invariante |
|:-:|:-----------|
| 1 | Nombres únicos |
| 2 | Ningún nodo del AST reclamado por dos constructos |
| 3 | Ningún token reclamado por dos constructos `LEAD` |
| 4 | Toda dependencia de `deps` resuelve a un constructo registrado |
| 5 | **Ningún sub-constructo huérfano**: todo `SUB` es alcanzable desde algún padre |
| 6 | Toda palabra clave lexa **realmente** al token que el constructo declara (cruce con `lexer.c`) |
| 7 | Bit de fase ⇔ hook presente, en los tres sentidos |
| 8 | `phases` sin bits desconocidos |
| 9 | Todo constructo tiene producción EBNF **y** cita a un reporte de investigación |
| 10 | Todo constructo declara al menos una posición gramatical |
| 11 | Todo constructo con `in_astra0 == false` explica **por qué** en `note` |
| 12 | Un tipo no puede tener cuerpo con llaves |
| 13 | Todo constructo de sentencia/ítem sin palabra clave tiene token de puntuación |
| 14 | La tabla de operadores coincide con el parser: **potencia de binding y `BinaryOp` elemento a elemento** |

Verificado por inyección de fallo: al escribir `"iff"` en el `keyword` de `if.c`
el self-check responde

```
  FAIL `if`: keyword "iff" lexes to IDENT but the construct declares if
```

(los invariantes 6 y 14 cruzan el registro con `lexer.c` y `parser.c` de
verdad, no con copias).

---

## 5. Desviaciones encontradas entre la investigación y el código

El registro sirvió, ya en su primer día, para hacer visibles contradicciones
que estaban repartidas por el código. Todas verificadas leyendo `research/010`.

| # | Hallazgo | Qué hace el seed |
|:-:|:---------|:-----------------|
| 1 | **§12.2 contradice a §12.1**: la fila 13 pone la asignación en la precedencia **más alta**, pero §12.1 dice `Expression ::= Assignment`, es decir el nivel **más flojo** | Sigue §12.1, como Rust y C. Documentado en `assign.c` y en la entrada de la tabla |
| 2 | **§12.2 agrupa `==`/`!=` con `<`/`>`/`<=`/`>=`** en la fila 6 | Se separan: igualdad liga más flojo que comparación, para que `a < b == c < d` sea `(a < b) == (c < d)` |
| 3 | **`**` (fila 10, asociativa a derecha) está especificado y no implementado** | Registrado en `astra_pending_operators` y visible en `--dump-operators` |
| 4 | **Los rangos como expresión no tienen fila en §12.2**: §12.1 solo usa `..` en `RangePattern` y en el *slice* `[a..b]` | El seed los añadió como expresión (potencia 2) para que `for i in 0..n` se lea natural. Documentado en `range.c` |
| 5 | **`TypeAlias ::= "type" Identifier ("=" \| "<" GenericParams ">") Type`** — la rama de genéricos no lleva `=`, así que no tiene tipo destino; la producción parece truncada | `type_alias.c` lo registra; el reporte debería corregirse |
| 6 | **`ImplBlock ::= "impl" GenericParams? Type …`** — `GenericParams?` sin ángulos, a diferencia de `FunctionDef`/`StructDef`/`EnumDef` que lo envuelven en `< >`; tal cual es ambiguo | `impl.c` lo registra |
| 7 | **§7.2 dice "~60 tokens"**; el enum `TokenKind` del seed tiene **75** | Sin acción; el conteo del reporte está desactualizado |

Los huecos **deliberados** (especificados, fuera de Astra-0) quedan registrados
como constructos con `in_astra0 = false` y su justificación citada:
`trait`, `impl`, `import`, `type_alias`, `comptime`, `lambda`, `tuple_lit`,
`pattern_ident`. `research/011` §5.2/§5.4 es la razón de cada uno.

---

## 6. Cómo añadir un constructo

```bash
cp src/constructs/binary_op.c src/constructs/<nombre>.c
#  1. rellenar el ConstructSpec (grammar y research son obligatorios)
#  2. añadirlo a registry.c
#  3. si tiene palabra clave, añadir el token a lexer.c
make && ./astra-seed --check-constructs
```

El self-check te dirá exactamente qué falta. Los pasos 1–2 son la lista
completa: no hay un quinto sitio que recordar.

---

## 7. Estado de la migración

`--check-constructs` reporta el progreso:

```
construct registry: 44 constructs
sub-constructs: 12
migrated (all three phases): 0 / 44
```

En este commit el registro **describe** los 44 constructos pero todavía no
ejecuta ninguno: `phases` es 0 en todos y los hooks son `NULL`. Eso es
deliberado y es la razón de que los 27 tests sigan en verde — este hito es
puramente aditivo y auditable.

La migración de los hooks va por fases, y cada fase es verificable por sí sola:

1. **parse** — mover `parse_if` / `parse_else` / `parse_while` / … a su archivo.
   Requiere una API de servicios del parser (`parser_internal.h`) porque hoy
   `advance`, `check`, `expect`, `parse_block`… son `static` dentro de
   `parser.c`. Empieza por `if` y `else` (el par que pediste), que son los que
   más se benefician de estar separados.
2. **emit** — el `switch` del emisor pasa a despachar por
   `construct_by_node(node->kind)->emit`. Es aquí donde `else` cobra sentido
   propio: hoy el parcheo del `JUMP_IF_FALSE` del `if` ya se equivocó una vez
   por un off-by-one.
3. **check** — igual para el type checker. `match` y su exhaustividad
   (`research/04` §9.7) son los que más ganan.

Cada fase se commitea por separado y `migrated: N / 44` es la métrica.

### Guardarraíl

`research/011` §2.3 avisa contra **sobre-ingeniería del seed**: "es desechable,
escribe rápido y sucio". El registro no contradice ese aviso mientras se
respeten dos reglas:

- El registro es **declarativo**: describe, no abstrae. No hay vtable, ni
  registro dinámico, ni carga en tiempo de ejecución, ni un generador de
  código. Son 44 structs constantes y unas tablas de punteros.
- Ningún archivo de constructo **añade** un concepto al lenguaje. Cada uno
  documenta un constructo que ya existe en `research/010`, o marca
  explícitamente uno que está fuera de Astra-0.

Si un archivo de constructo empieza a contener lógica que no es "parsear /
chequear / emitir este constructo", la sobre-ingeniería ha empezado y hay que
parar.

---

## 8. Orden recomendado para lo que queda

Derivado de los huecos registrados en los propios archivos:

1. **`pattern_ident`** — es el desbloqueo. Sin binding de patrones no hay
   variantes con datos, ni patrones anidados, ni `let` con destructuring
   (`research/04` §9.4, §8.2). Todo lo demás de la lista depende de esto.
2. **`enum_variant` con payload** — variantes con datos y el nodo propio que
   hoy no existe (hoy `Enum.Variant` se baja a `NODE_FIELD_ACCESS`);
   `research/04` §9.3 y las decisiones de layout de §6.2-6.4.
3. **`match_arm` guards** — hoy el parser los **rechaza** explícitamente en vez
   de aceptarlos y silenciosamente ignorarlos.
4. **`Option` / `Result` y el operador `?`** — `research/04` §9.6; `?` está en
   §12.2 fila 12 y su entrada de tabla ya está puesta con potencia 0
   ("especificado, sin entrada en el Pratt").
5. **`index` con slices** (`xs[a..b]`) — necesita un tipo vista y un modelo de
   préstamo que el seed conscientemente no tiene.
