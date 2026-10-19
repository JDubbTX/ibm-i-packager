/* ========================================================================== */
/* Sample ILE C Program: UTLCLP.C                                             */
/* Built with IBM i TOBi (makei) -> *PGM (CLE) - Precedence Tier 70           */
/* Normalizes and trims an order reference code passed from CL/RPG.           */
/* ========================================================================== */
#include <stdio.h>
#include <string.h>
#include <ctype.h>

int main(int argc, char *argv[]) {
    if (argc > 1 && argv[1] != NULL) {
        for (int i = 0; i < 10 && argv[1][i] != '\0'; i++) {
            argv[1][i] = (char)toupper((unsigned char)argv[1][i]);
        }
    }
    return 0;
}
