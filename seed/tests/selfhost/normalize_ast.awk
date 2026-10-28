# normalize_ast.awk — turn `astra-seed --dump-ast` (indented tree) into the
# one-line prefix s-expression that parser.astra emits (DEC-025).
#
#   astra-seed --dump-ast f.astra | awk -f normalize_ast.awk
#
# Layout: every level is 2 spaces. Each line is a node text; a node's payload
# (when the dump prints one, e.g. `FnDecl(main)`, `IntLit(10)`) travels inside
# the text. Children are attached as `text(kid1 kid2 ...)`; when the text
# already ends in `)` the kids go before that paren, so `FnDecl(main)` with
# children becomes `FnDecl(main Param(...))`. A childless node stays as-is
# (`Break`, `Module` with no items).
#
# Deliberately dumb: no knowledge of node names, so it cannot "agree" with
# parser.astra on anything but shape. Anything it cannot parse still flows
# through, where the gate diff fails loudly.

function serialize(t, k,    i, p) {
    if (k == "") return t
    # insert kids before the LAST ")" of t, if t ends with one
    p = 0
    for (i = length(t); i >= 1; i--)
        if (substr(t, i, 1) == ")") { p = i; break }
    if (p == 0 || substr(t, length(t), 1) != ")")
        return t "(" k ")"
    return substr(t, 1, p - 1) " " k substr(t, p)
}

function finish(d,    s) {
    if (txt[d] == "") return
    s = serialize(txt[d], kids[d])
    if (d == 0) root = s
    else kids[d - 1] = (kids[d - 1] == "" ? s : kids[d - 1] " " s)
    txt[d] = ""; kids[d] = ""
}

{
    line = $0
    match(line, /^ */)
    ind = RLENGTH
    if (substr(line, ind + 1) == "") next        # blank line
    d = int(ind / 2)
    if (ind % 2 != 0) print "UNLANNED-ODD-INDENT: " line > "/dev/stderr"
    # every open node at depth >= d is complete: its next line is a sibling
    # (same depth) or a descendant of an ancestor (smaller depth)
    for (k = prev; k >= d; k--) finish(k)
    txt[d] = substr(line, ind + 1)
    kids[d] = ""
    prev = d
}

END {
    for (k = prev; k >= 0; k--) finish(k)
    print root
}
