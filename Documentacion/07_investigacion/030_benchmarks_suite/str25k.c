#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
    char *s = malloc(1);
    size_t len = 0;
    s[0] = '\0';
    for (int i = 0; i < 25000; i++) {
        char *ns = malloc(len + 2);
        memcpy(ns, s, len);
        ns[len] = 'x';
        ns[len + 1] = '\0';
        free(s);
        s = ns;
        len++;
    }
    printf("%s\n", s);
    free(s);
    return 0;
}
