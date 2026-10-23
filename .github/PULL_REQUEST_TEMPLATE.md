<!-- Gracias por contribuir a Astra. Rellena las secciones que apliquen. -->

## ¿Qué hace este cambio?

<!-- Describe el objetivo y el "por qué". Enlaza el issue si aplica: Fixes #NN -->

## Tipo de cambio

- [ ] `feat` — funcionalidad nueva (requiere test de conformidad en `seed/tests/`)
- [ ] `fix` — arreglo de bug
- [ ] `docs` — solo documentación
- [ ] `test` — solo tests
- [ ] `refactor` / `chore` — sin cambio de comportamiento

## Checklist

- [ ] **Commits firmados**: los commits de este PR están firmados
      (`git log --show-signature` / el badge "Verified" en GitHub). La política
      de `main` **rechaza commits sin firmar**.
- [ ] **Tests locales en verde**:
      - `cd seed && make test` (si toca el compilador C / conformance / codegen)
      - `cd zig && zig build test` (si toca el compilador Zig)
      - `zig build -Dllvm && ./tests/llvm_parity.sh` (si toca el backend LLVM)
- [ ] **Sin secretos**: no hay tokens, claves, passwords ni `.env` en el diff.
      (El push protection del secret scanning bloqueará el push si los hay.)
- [ ] **Nuevos comportamientos con tests**: toda conducta nueva del lenguaje
      tiene su caso en `seed/tests/conformance/` o `tests/codegen/`.
- [ ] **Documentación al día**: `Documentacion/`, `AGENTS.md` y progreso
      actualizados si el cambio afecta diseño o flujo de trabajo.
- [ ] **Conventional commits**: mensajes con prefijo `feat(scope):`,
      `fix(scope):`, `docs:`, etc.

## Notas para el revisor

<!-- Opcional: riesgos, decisiones alternativas, qué mirar primero -->

## Evidencia de verificación

<!-- Pega la salida resumida de los gates que corriste, p. ej.:
     `make test`: 155/155 conformance ok; `llvm_parity.sh`: 155/155 -->
