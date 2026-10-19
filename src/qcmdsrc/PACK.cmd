/* ========================================================================= */
/* Command:     #PACK                                                        */
/* Source File: PACK.cmd                                                     */
/* CPP:         PACKC                                                        */
/* Description: Package IBM i CI/CD objects into a Save File or IFS path     */
/*              and stamp all packaged objects with a 10-char Version ID     */
/*              in the User-Defined Attribute (USRDFNATR).                   */
/*                                                                           */
/* Compile:                                                                  */
/*   CRTCMD CMD(&INTO/#PACK) PGM(&INTO/PACKC) SRCFILE(&SRCLIB/QCMDSRC)       */
/*          SRCMBR(PACK) ALLOW(*ALL)                                         */
/* ========================================================================= */
             CMD        PROMPT('Package IBM i Objects (#PACK)')

             /* Source Library containing objects to package */
             PARM       KWD(SRCLIB) TYPE(*NAME) LEN(10) MIN(1) +
                          EXPR(*YES) +
                          PROMPT('Source library')

             /* Object name(s) or generic pattern(s) to include */
             PARM       KWD(OBJ) TYPE(*GENERIC) LEN(10) DFT(*ALL) +
                          SPCVAL((*ALL)) MAX(50) EXPR(*YES) +
                          PROMPT('Objects to package')

             /* Object types to include */
             PARM       KWD(OBJTYPE) TYPE(*CHAR) LEN(10) RSTD(*YES) +
                          DFT(*ALL) +
                          VALUES(*ALL *PGM *SRVPGM *MODULE *FILE +
                                 *SQLPKG *BNDDIR *DTAARA *DTAQ +
                                 *MSGF *CMD *PNLGRP *MENU *JOBD +
                                 *CLS *SBSD *OUTQ *WSCST *AUTL) +
                          MAX(20) EXPR(*YES) +
                          PROMPT('Object types')

             /* 10-Character Version Stamp applied to USRDFNATR */
             PARM       KWD(VERSION) TYPE(*CHAR) LEN(10) MIN(1) +
                          EXPR(*YES) +
                          PROMPT('Package version (10 chars)')

             /* Output destination type: IBM i Save File or IFS path */
             PARM       KWD(OUTTYPE) TYPE(*CHAR) LEN(6) RSTD(*YES) +
                          DFT(*SAVF) VALUES(*SAVF *STMF) EXPR(*YES) +
                          PROMPT('Output destination type')

             /* Target Save File (when OUTTYPE = *SAVF) */
             PARM       KWD(SAVF) TYPE(SAVFQUAL) +
                          PMTCTL(PMTSAVF) +
                          PROMPT('Target save file')

             /* Target IFS Stream File or Directory (when OUTTYPE = *STMF) */
             PARM       KWD(STMF) TYPE(*PNAME) LEN(256) DFT(*NONE) +
                          SPCVAL((*NONE)) EXPR(*YES) +
                          PMTCTL(PMTSTMF) +
                          PROMPT('Target IFS file or directory')

             /* Target OS Release for SAVOBJ */
             PARM       KWD(TGTRLS) TYPE(*CHAR) LEN(10) +
                          DFT(*CURRENT) SPCVAL((*CURRENT) (*PRV)) +
                          EXPR(*YES) +
                          PROMPT('Target release')

             /* Replace/clear existing output file */
             PARM       KWD(CLEAR) TYPE(*CHAR) LEN(4) RSTD(*YES) +
                          DFT(*YES) VALUES(*YES *NO) EXPR(*YES) +
                          PROMPT('Replace existing output')

             /* HTML Manifest Report Output Path in IFS */
             PARM       KWD(MANIFEST) TYPE(*PNAME) LEN(256) +
                          DFT(*AUTO) SPCVAL((*AUTO) (*NONE)) +
                          EXPR(*YES) +
                          PROMPT('HTML manifest path (IFS)')

             /* Qualified Save File Name Definition */
 SAVFQUAL:   QUAL       TYPE(*NAME) LEN(10) DFT(PKGSAVF) EXPR(*YES)
             QUAL       TYPE(*NAME) LEN(10) DFT(QTEMP) +
                          SPCVAL((*CURLIB) (QTEMP)) EXPR(*YES) +
                          PROMPT('Library')

             /* Prompt Controls */
 PMTSAVF:    PMTCTL     CTL(OUTTYPE) COND((*EQ '*SAVF'))
 PMTSTMF:    PMTCTL     CTL(OUTTYPE) COND((*EQ '*STMF'))

             /* Cross-parameter Dependency Checks */
             DEP        CTL(&OUTTYPE *EQ '*STMF') +
                          PARM((&STMF *NE '*NONE')) +
                          MSGID(CPD0006)
