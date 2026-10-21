# Core Source Directory Rules (`src/`)

These rules apply whenever modifying files under [`src/`](.) (`qcmdsrc/`, `qcllesrc/`, `qrpglesrc/`).

---

## 1. Parameter Contract Synchronization (`.cmd` $\leftrightarrow$ `.clle` $\leftrightarrow$ `.sqlrpgle`)

Whenever adding, removing, or resizing a command parameter, all three layers **must** be updated in lockstep:

### `#PACK` (`PACK`) Pipeline
1. **Command Definition ([`src/qcmdsrc/PACK.cmd`](qcmdsrc/PACK.cmd))**:
   - Defines `PARM` keywords in exact positional order: `SRCLIB`, `OBJ`, `OBJTYPE`, `VERSION`, `OUTTYPE`, `SAVF`, `STMF`, `TGTRLS`, `CLEAR`, `MANIFEST`.
   - Note how CL `MAX(50)` / `MAX(20)` list parameters pass a 2-byte binary count prefix followed by fixed-width elements:
     - `OBJ` (`CHAR(10) MAX(50)`) $\rightarrow$ `2 + (50 * 10) = 502` bytes (`ElemList50_t` in [`PKGTYPES.rpgleinc`](qrpglesrc/PKGTYPES.rpgleinc)).
     - `OBJTYPE` (`CHAR(10) MAX(20)`) $\rightarrow$ `2 + (20 * 10) = 202` bytes (`ElemList20_t` in [`PKGTYPES.rpgleinc`](qrpglesrc/PKGTYPES.rpgleinc)).
2. **CL Command Processing Program ([`src/qcllesrc/PACKC.pgm.clle`](qcllesrc/PACKC.pgm.clle))**:
   - Receives `PGM PARM(&SRCLIB &OBJLST &TYPLST &VERSION &OUTTYPE &SAVFQUAL &STMF &TGTRLS &CLEAR &MANIFEST)`.
   - CL program sources must be named `*.pgm.clle`: TOBi maps `NAME.PGM: NAME.clle` to a nonexistent `CLLE_TO_PGM_RECIPE` and silently skips the compile. TOBi's `CRTBNDCL` also ignores `DFTACTGRP`/`ACTGRP` from `Rules.mk`, so keep `DCLPRCOPT DFTACTGRP(*NO) ACTGRP(*NEW)` in the source.
   - Prepares the target or `QTEMP/PKGSAVF` staging save file, calls `PACKR`, and if `OUTTYPE(*STMF)` exports the save file via `CPYTOSTMF ... CVTDTA(*NONE) ENDLINFMT(*FIXED)`.
3. **SQLRPGLE Engine ([`src/qrpglesrc/PACKR.sqlrpgle`](qrpglesrc/PACKR.sqlrpgle))**:
   - `dcl-pi PACKR;` must match the exact 14 parameters passed by `CALL PGM(PACKR)` in [`PACKC.pgm.clle`](qcllesrc/PACKC.pgm.clle).

### `#UNPACK` (`UNPACK`) Pipeline
1. **Command Definition ([`src/qcmdsrc/UNPACK.cmd`](qcmdsrc/UNPACK.cmd))**:
   - Defines `PARM` keywords in exact positional order: `INPTYPE`, `SAVF`, `STMF`, `DFTLIB`, `LIBMAP`, `MAPFILE`, `CPYDTA`, `BKPSAVF`, `MANIFEST`.
   - `LIBMAP` (`MAX(30)` mixed list of 3 `CHAR(10)` elements) uses `LibMapList_t` (`CHAR(1024)` with 2-byte count + 30 offsets + 30 `LibMapElem_t` entries).
2. **CL Command Processing Program ([`src/qcllesrc/UNPACKC.pgm.clle`](qcllesrc/UNPACKC.pgm.clle))**:
   - When `INPTYPE(*STMF)`, copies the IFS stream file into `QTEMP/UNPKSAVF` using:
     ```cl
     CPYFRMSTMF FROMSTMF(&STMF) TOMBR(&TOMBR) MBROPT(*REPLACE) CVTDTA(*NONE)
     ```
     **Important**: Never add `ENDLINFMT(*FIXED)` to `CPYFRMSTMF` (it is only valid on `CPYTOSTMF` and causes a CL compile error on `CPYFRMSTMF`).
3. **SQLRPGLE Engine ([`src/qrpglesrc/UNPACKR.sqlrpgle`](qrpglesrc/UNPACKR.sqlrpgle))**:
   - `dcl-pi UNPACKR;` must match the exact 13 parameters passed by `CALL PGM(UNPACKR)` in [`UNPACKC.pgm.clle`](qcllesrc/UNPACKC.pgm.clle).

---

## 2. Database File Replacement & Pseudo-Closed SQL Cursor Locks

In [`src/qrpglesrc/UNPACKR.sqlrpgle`](qrpglesrc/UNPACKR.sqlrpgle), when replacing an existing `*FILE` (`PF` / SQL `TABLE`):
- Db2 for i often holds pseudo-closed SQL cursor locks on tables that were queried or modified earlier in the same job.
- Before executing `RNMOBJ` or `DLTF` on a `*FILE`, **always** request cursor lock release using:
  ```rpgle
  RunClCommand('ALCOBJ OBJ((' + %trim(Lib) + '/' + %trim(File)
               + ' *FILE *EXCL)) WAIT(0) CONFLICT(*RQSRLS)');
  RunClCommand('DLCOBJ OBJ((' + %trim(Lib) + '/' + %trim(File)
               + ' *FILE *EXCL))');
  ```
- When running `DSPDBR` to discover dependent Logical Files in `SuspendDependentLfs`, use `OUTFILE(QTEMP/DBROUT) OUTMBR(*FIRST *REPLACE)` after releasing any cursor lock on `QTEMP/DBROUT`.

---

## 3. Dependency Precedence Tiers (`PKGTYPES.rpgleinc`)

The 8 unpack precedence tiers defined in [`src/qrpglesrc/PKGTYPES.rpgleinc`](qrpglesrc/PKGTYPES.rpgleinc) and assigned in `DeterminePrecedenceTier` in [`src/qrpglesrc/UNPACKR.sqlrpgle`](qrpglesrc/UNPACKR.sqlrpgle) must preserve this strict ordering:
- `TIER_SECURITY_SYS (10)`: `*AUTL`, `*CLS`, `*JOBD`, `*SBSD`, `*OUTQ`, `*WSCST`
- `TIER_DATA_CONTAINERS (15)`: `*MSGF`, `*DTAARA`, `*DTAQ`
- `TIER_PHYSICAL_DATA (20)`: `*FILE` with `PF`, `PF-DTA`, `PF-SRC`, `TB`
- `TIER_LOGICAL_DATA (30)`: `*FILE` with `LF`, `VW`, `IX`, `MQT`
- `TIER_DEVICE_UI (40)`: `*FILE` with `DSPF`, `PRTF`, `ICFF`, plus `*PNLGRP`, `*MENU`
- `TIER_MODULES_BND (50)`: `*MODULE`, `*BNDDIR`
- `TIER_SERVICE_PGMS (60)`: `*SRVPGM`
- `TIER_PROGRAMS (70)`: `*PGM`, `*SQLPKG`
- `TIER_COMMANDS_OTHER (80)`: `*CMD` and all remaining types

---

## 4. TOBi (`Rules.mk`) Rules in `src/`

- In [`src/qcmdsrc/Rules.mk`](qcmdsrc/Rules.mk), always set **both** `CMD_PGM` and `PGM` (e.g., `PACK.CMD: PGM = PACKC`) so TOBi's `CRTCMD` recipe passes `PGM(PACKC)` to `crtfrmstmf`.
- In [`src/qrpglesrc/Rules.mk`](qrpglesrc/Rules.mk), keep `private COMMIT = *NONE` and `private RPGPPOPT = *LVL2` on `PACKR.PGM` and `UNPACKR.PGM`.

