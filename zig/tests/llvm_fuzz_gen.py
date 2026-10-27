#!/usr/bin/env python3
"""Generador determinista de programas Astra para el fuzz diferencial (M3).

    llvm_fuzz_gen.py --seed S --index I

Emite en stdout un programa reproducible a partir de (S, I). Solo usa el
subconjunto que las cuatro rutas ya cubren — escalares i64 con sus guards,
strings con escapes, if/while, arrays con índice (a veces fuera de rango),
structs, enums con match de payload y Option/Result con `?` — así que
cualquier divergencia entre rutas es un bug real del backend, no una
limitación conocida del emisor. Los programas son de tamaño acotado: el
fuzz compara bytes, no busca cobertura.
"""

import argparse
import random

# DEC-006: los literales deben caber en i32 (los contextos anotados del
# generador son i32); i64-max se probaba antes y ahora no compila.
INT_LITERALS = ["0", "1", "2", "3", "5", "7", "11", "100", "-1", "-2", "2147483647", "-2147483648"]
STR_LITERALS = ['"a"', '"hola"', '"x y"', '"he said \\"hi\\""', '"line\\nbreak"', '"tab\\there"', '""']


class Gen:
    def __init__(self, rng):
        self.rng = rng
        self.ints = []      # nombres de variables i32 en scope
        self.bools = []
        self.strs = []
        self.arrs = []      # (nombre, longitud)
        self.structs = []   # nombres de Point
        self.enums = []     # nombres de Kind
        self.opts = []      # nombres de i32?
        self.n = 0

    def fresh(self, prefix):
        self.n += 1
        return "%s%d" % (prefix, self.n)

    # ── expresiones ────────────────────────────────────────────────────────

    def int_expr(self, d):
        kinds = ["lit", "bin", "neg", "if", "call"]
        if self.ints:
            kinds += ["var", "var"]
        if self.arrs:
            kinds += ["index", "index"]
        if d <= 0:
            kinds = ["lit"] + (["var"] if self.ints else [])
        k = self.rng.choice(kinds)
        if k == "lit":
            return self.rng.choice(INT_LITERALS)
        if k == "var":
            return self.rng.choice(self.ints)
        if k == "neg":
            return "-(" + self.int_expr(d - 1) + ")"
        if k == "bin":
            op = self.rng.choice(["+", "-", "*", "/", "%", "+", "*"])
            # Un 0 a la derecha ejercita el guard de división/módulo.
            rhs = "0" if op in ("/", "%") and self.rng.random() < 0.4 else self.int_expr(d - 1)
            return "(" + self.int_expr(d - 1) + " " + op + " " + rhs + ")"
        if k == "if":
            return "(if " + self.bool_expr(d - 1) + " { " + self.int_expr(d - 1) + " } else { " + self.int_expr(d - 1) + " })"
        if k == "call":
            return "combine(" + self.int_expr(d - 1) + ", " + self.int_expr(d - 1) + ")"
        # index: índice literal dentro o fuera de rango, o una variable
        name, length = self.rng.choice(self.arrs)
        if self.rng.random() < 0.5:
            idx = str(self.rng.randint(0, length + 1))
        elif self.ints:
            idx = self.rng.choice(self.ints)
        else:
            idx = str(self.rng.randint(0, length))
        return name + "[" + idx + "]"

    def bool_expr(self, d):
        kinds = ["lit", "cmp", "strcmp", "not"]
        if self.bools:
            kinds += ["var", "and", "or"]
        if d <= 0:
            kinds = ["lit"] + (["var"] if self.bools else [])
        k = self.rng.choice(kinds)
        if k == "lit":
            return self.rng.choice(["true", "false"])
        if k == "var":
            return self.rng.choice(self.bools)
        if k == "not":
            return "!" + self.bool_expr(d - 1)
        if k == "and":
            return "(" + self.bool_expr(d - 1) + " && " + self.bool_expr(d - 1) + ")"
        if k == "or":
            return "(" + self.bool_expr(d - 1) + " || " + self.bool_expr(d - 1) + ")"
        if k == "strcmp":
            return "(" + self.str_expr(d - 1) + " == " + self.str_expr(d - 1) + ")"
        op = self.rng.choice(["<", "<=", ">", ">=", "==", "!="])
        return "(" + self.int_expr(d - 1) + " " + op + " " + self.int_expr(d - 1) + ")"

    def str_expr(self, d):
        kinds = ["lit", "cat"]
        if self.strs:
            kinds += ["var", "var"]
        if d <= 0:
            kinds = ["lit"] + (["var"] if self.strs else [])
        k = self.rng.choice(kinds)
        if k == "lit":
            return self.rng.choice(STR_LITERALS)
        if k == "var":
            return self.rng.choice(self.strs)
        return "(" + self.str_expr(d - 1) + " + " + self.str_expr(d - 1) + ")"

    # ── programa ───────────────────────────────────────────────────────────

    def program(self):
        out = []
        out.append("// Fuzz diferencial (M3): programa generado, no editar a mano.")
        out.append("struct Point {")
        out.append("    x: i32")
        out.append("    y: i32")
        out.append("}")
        out.append("")
        out.append("enum Kind {")
        out.append("    Num(i32)")
        out.append("    Empty")
        out.append("}")
        out.append("")
        out.append("fn combine(a: i32, b: i32) -> i32 {")
        out.append("    a * 2 + b")
        out.append("}")
        out.append("")
        out.append("fn half(x: i32) -> i32? {")
        out.append("    if x % 2 != 0 { return none }")
        out.append("    some(x / 2)")
        out.append("}")
        out.append("")
        out.append("fn quarter(x: i32) -> i32? {")
        out.append("    let h = half(x)?")
        out.append("    some(h / 2)")
        out.append("}")
        out.append("")
        out.append("fn main() {")

        # 1) bindings escalares
        for _ in range(self.rng.randint(1, 3)):
            name = self.fresh("n")
            out.append("    let " + name + ": i32 = " + self.int_expr(2))
            self.ints.append(name)
            out.append("    print(" + name + ")")
        for _ in range(self.rng.randint(0, 2)):
            name = self.fresh("b")
            out.append("    let " + name + ": bool = " + self.bool_expr(2))
            self.bools.append(name)
            out.append("    print(" + name + ")")
        for _ in range(self.rng.randint(0, 2)):
            name = self.fresh("s")
            out.append("    let " + name + ": string = " + self.str_expr(2))
            self.strs.append(name)
            out.append("    print(" + name + ")")

        # 2) if como sentencia
        out.append("    if " + self.bool_expr(2) + " {")
        out.append("        print(" + self.int_expr(2) + ")")
        out.append("    } else {")
        out.append("        print(" + self.int_expr(2) + ")")
        out.append("    }")

        # 3) array + índice (puede salirse de rango: guard comparable)
        aname = self.fresh("a")
        n_elems = self.rng.randint(1, 4)
        elems = ", ".join(self.int_expr(1) for _ in range(n_elems))
        out.append("    let " + aname + " = [" + elems + "]")
        self.arrs.append((aname, n_elems))
        out.append("    print(" + self.int_expr(2) + ")")

        # 4) struct: literal, lectura de campo y eq estructural
        pname = self.fresh("p")
        out.append("    let " + pname + " = Point { x: " + self.int_expr(1) + ", y: " + self.int_expr(1) + " }")
        self.structs.append(pname)
        out.append("    print(" + pname + ".x + " + pname + ".y)")
        out.append("    print(" + pname + " == Point { x: " + pname + ".x, y: " + pname + ".y })")

        # 5) enum + match con binding de payload
        ename = self.fresh("e")
        if self.rng.random() < 0.7:
            out.append("    let " + ename + " = Num(" + self.int_expr(1) + ")")
        else:
            out.append("    let " + ename + " = Kind.Empty")
        self.enums.append(ename)
        out.append("    print(match " + ename + " {")
        out.append("        Kind.Num(v) => v * 3,")
        out.append("        Kind.Empty => -1,")
        out.append("    })")

        # 6) Option + match
        oname = self.fresh("o")
        if self.rng.random() < 0.6:
            out.append("    let " + oname + ": i32? = some(" + self.int_expr(1) + ")")
        else:
            out.append("    let " + oname + ": i32? = none")
        self.opts.append(oname)
        out.append("    print(match " + oname + " {")
        out.append("        some(v) => v,")
        out.append("        none => -7,")
        out.append("    })")

        # 7) `?` a través de dos frames (caja none / some)
        out.append("    print(quarter(" + self.int_expr(1) + "))")

        # 8) while acotado con var
        wname = self.fresh("w")
        limit = self.rng.randint(0, 3)
        out.append("    let mut " + wname + ": i32 = 0")
        out.append("    while " + wname + " < " + str(limit) + " {")
        out.append("        print(" + wname + ")")
        out.append("        " + wname + " = " + wname + " + 1")
        out.append("    }")
        out.append("}")
        return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--index", type=int, default=0)
    args = ap.parse_args()
    rng = random.Random("%d-%d" % (args.seed, args.index))
    print(Gen(rng).program(), end="")


if __name__ == "__main__":
    main()
