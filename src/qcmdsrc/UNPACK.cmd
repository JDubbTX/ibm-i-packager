/* ========================================================================= */
/* Command:     #UNPACK                                                      */
/* Source File: UNPACK.cmd                                                   */
/* CPP:         UNPACKC                                                      */
/* Description: Unpackage IBM i CI/CD Save File or IFS package in strict     */
/*              object dependency precedence order, supporting library       */
/*              mapping by object type/attribute, authority preservation     */
/*              from existing objects, PF/Table data migration, and          */
/*              rollback backup save files.                                  */
/*                                                                           */
/* Compile:                                                                  */
/*   CRTCMD CMD(&INTO/#UNPACK) PGM(&INTO/UNPACKC) SRCFILE(&SRCLIB/QCMDSRC)   */
/*          SRCMBR(UNPACK) ALLOW(*ALL)                                       */
/* ========================================================================= */
             CMD        PROMPT('Unpackage Objects (#UNPACK)')

             /* Input package source type: Save File or IFS Stream File */
             PARM       KWD(INPTYPE) TYPE(*CHAR) LEN(6) RSTD(*YES) +
                          DFT(*SAVF) VALUES(*SAVF *STMF) EXPR(*YES) +
                          PROMPT('Input package type')

             /* Input Save File (when INPTYPE = *SAVF) */
             PARM       KWD(SAVF) TYPE(SAVFQUAL) +
                          PMTCTL(PMTSAVF) +
                          PROMPT('Package save file')

             /* Input IFS Stream File (when INPTYPE = *STMF) */
             PARM       KWD(STMF) TYPE(*PNAME) LEN(256) DFT(*NONE) +
                          SPCVAL((*NONE)) EXPR(*YES) +
                          PMTCTL(PMTSTMF) +
                          PROMPT('Package IFS stream file')

             /* Default Target Library (when not matched in LIBMAP) */
             PARM       KWD(DFTLIB) TYPE(*NAME) LEN(10) DFT(*SAVLIB) +
                          SPCVAL((*SAVLIB)) EXPR(*YES) +
                          PROMPT('Default target library')

             /* Library Map by Object Type and Extended Attribute */
             PARM       KWD(LIBMAP) TYPE(MAPELEM) MAX(30) +
                          DFT(*NONE) SNGVAL((*NONE)) +
                          PROMPT('Target library map by type')

             /* JSON File (IFS) for Library Mapping & File Data Overrides */
             PARM       KWD(MAPFILE) TYPE(*PNAME) LEN(256) DFT(*NONE) +
                          SPCVAL((*NONE)) EXPR(*YES) +
                          PROMPT('Library map JSON file (IFS)')

             /* Preserve existing data in Physical Files / SQL Tables */
             PARM       KWD(CPYDTA) TYPE(*CHAR) LEN(4) RSTD(*YES) +
                          DFT(*YES) VALUES(*YES *NO) EXPR(*YES) +
                          PROMPT('Preserve PF/Table data')

             /* Optional Rollback / Backup Save File for replaced objects */
             PARM       KWD(BKPSAVF) TYPE(BKPQUAL) +
                          PROMPT('Rollback backup save file')

             /* HTML Unpack Manifest Report Output Path in IFS */
             PARM       KWD(MANIFEST) TYPE(*PNAME) LEN(256) +
                          DFT(*AUTO) SPCVAL((*AUTO) (*NONE)) +
                          EXPR(*YES) +
                          PROMPT('HTML manifest path (IFS)')

             /* Qualified Package Save File */
 SAVFQUAL:   QUAL       TYPE(*NAME) LEN(10) DFT(PKGSAVF) EXPR(*YES)
             QUAL       TYPE(*NAME) LEN(10) DFT(QTEMP) +
                          SPCVAL((*CURLIB) (QTEMP)) EXPR(*YES) +
                          PROMPT('Library')

             /* Qualified Rollback Backup Save File */
 BKPQUAL:    QUAL       TYPE(*NAME) LEN(10) DFT(*NONE) +
                          SPCVAL((*NONE)) EXPR(*YES)
             QUAL       TYPE(*NAME) LEN(10) DFT(QTEMP) +
                          SPCVAL((*CURLIB) (QTEMP)) EXPR(*YES) +
                          PROMPT('Library')

             /* Library Mapping Element: (ObjType, ExtendedAttr, TargetLib) */
 MAPELEM:    ELEM       TYPE(*CHAR) LEN(10) RSTD(*YES) +
                          VALUES(*ALL *PGM *SRVPGM *MODULE *FILE +
                                 *SQLPKG *BNDDIR *DTAARA *DTAQ +
                                 *MSGF *CMD *PNLGRP *MENU *JOBD +
                                 *CLS *SBSD *OUTQ *WSCST *AUTL) +
                          EXPR(*YES) +
                          PROMPT('Object type')
             ELEM       TYPE(*CHAR) LEN(10) DFT(*ALL) +
                          SPCVAL((*ALL)) EXPR(*YES) +
                          PROMPT('Object attribute (PF,LF,TB)')
             ELEM       TYPE(*NAME) LEN(10) MIN(1) EXPR(*YES) +
                          PROMPT('Target library')

             /* Prompt Controls */
 PMTSAVF:    PMTCTL     CTL(INPTYPE) COND((*EQ '*SAVF'))
 PMTSTMF:    PMTCTL     CTL(INPTYPE) COND((*EQ '*STMF'))

             /* Cross-parameter Dependency Checks */
             DEP        CTL(&INPTYPE *EQ '*STMF') +
                          PARM((&STMF *NE '*NONE')) +
                          MSGID(CPD0006)
