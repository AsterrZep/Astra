#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
int main(void) {
    int64_t s = 0;
    for (int i = 0; i < 2000000; i++) {
        int64_t *a = malloc(8 * sizeof(int64_t));
        for (int j = 0; j < 8; j++) a[j] = j + 1;
        s += a[0];
        free(a);
    }
    printf("%ld\n", (long)s);
    return 0;
}
