# AI Agent Development Guide (`ibm-i-packager`)

This document provides essential context, architectural invariants, and IBM i / ILE / TOBi / iRPGUnit rules for AI coding agents maintaining this repository.

> **Hierarchical Context**: Additional directory-scoped rules are located in:
> - [`src/AGENTS.md`](src/AGENTS.md) — Core `#PACK` / `#UNPACK` engines (`SQLRPGLE`, `CLLE`, `CMD`, QSYS APIs)
> - [`test/AGENTS.md`](test/AGENTS.md) — iRPGUnit (`RPGUNIT`) test suite & VS Code IBM i Testing extension rules
> - [`samples/AGENTS.md`](samples/AGENTS.md) — Multi-tier sample IBM i objects & TOBi (`makei`) build rules

---

## 1. Project Purpose & Architecture

`ibm-i-packager` is a native IBM i (`V7R4M0+`, `V7R3M0 TR9+`, `V7R5M0+`) CI/CD packaging and deployment toolkit consisting of two commands and their backing programs:

1. **`PACK` / `#PACK`**:
   - [`src/qcmdsrc/PACK.cmd`](src/qcmdsrc/PACK.cmd) $\rightarrow$ [`src/qcllesrc/PACKC.clle`](src/qcllesrc/PACKC.clle) $\rightarrow$ [`src/qrpglesrc/PACKR.sqlrpgle`](src/qrpglesrc/PACKR.sqlrpgle)
   - Discovers objects in `SRCLIB` via `QSYS2.OBJECT_STATISTICS`, stamps a **10-character version string** into each object's User-Defined Attribute (`USRDFNATR`) using the `QLICOBJD` system API (key `9`), saves the objects via `SAVOBJ` to a QSYS `*SAVF` or IFS `*STMF`, stamps the `*SAVF` itself, and generates an HTML manifest via `QSYS2.IFS_WRITE_UTF8`.
2. **`UNPACK` / `#UNPACK`**:
   - [`src/qcmdsrc/UNPACK.cmd`](src/qcmdsrc/UNPACK.cmd) $\rightarrow$ [`src/qcllesrc/UNPACKC.clle`](src/qcllesrc/UNPACKC.clle) $\rightarrow$ [`src/qrpglesrc/UNPACKR.sqlrpgle`](src/qrpglesrc/UNPACKR.sqlrpgle)
   - Inspects a package Save File using the **`QSRLSAVF`** API (format **`SAVF0200`**) into a user space (`QTEMP/UNPKSPC`), maps target libraries and `preserveData` flags via inline `LIBMAP` rules or an IFS JSON `MAPFILE` (`JSON_TABLE`), backs up existing objects to `BKPSAVF`, and restores objects in **strict 8-tier dependency precedence order** (`10` $\rightarrow$ `80`) while preserving existing object authorities (`QSYS2.OBJECT_PRIVILEGES` + `GRTOBJAUT REFOBJ`) and migrating existing PF/SQL Table records (`CPYF FMTOPT(*MAP *DROP)`).

---

## 2. Build System & Environment

- **Primary Build Tool**: [IBM i TOBi (`makei`)](https://github.com/IBM/ibmi-tobi) driven by [`iproj.json`](iproj.json), root [`Rules.mk`](Rules.mk), and per-directory `Rules.mk` files.
- **Target Library Configuration**:
  - Defined in `.env` (git-ignored, local to developer workspace):
    ```ini
    lib1=PACKAGER
    CURLIB=PACKAGER
    LIBL=RPGUNIT QGPL QTEMP
    ```
  - [`iproj.json`](iproj.json) references `"objlib": "&lib1"` and `"curlib": "&lib1"`, with `"preUsrlibl": ["RPGUNIT"]`.
- **Full Project Build Command** (in PASE on IBM i):
  ```bash
  export PATH=/QOpenSys/pkgs/bin:$PATH
  export lib1=PACKAGER
  makei build
  ```
- **Single-File Compile Command**:
  ```bash
  makei compile -f <filename>
  ```

---

## 3. Critical IBM i Platform Pitfalls & Invariants

When editing code or running commands on IBM i, **always** adhere to these platform rules:

1. **Multithreaded PASE Job Restriction (`CPD000D`)**:
   - Do **not** use `system -i "CRTSQLRPGI ..."` or `system -i "RPGUNIT/RUCALLTST ..."` in PASE. The `-i` flag runs the command in the multithreaded `QP0ZSPWP` PASE job, which causes `CRTSQLRPGI` and `RUCALLTST` to fail with `CPD000D: Command not safe for a multithreaded job`.
   - Instead, execute CL commands via `system "..."` (without `-i`, which spawns a single-threaded batch immediate job) or through a single-threaded `QSQSRVR` database connection (`CALL QSYS2.QCMDEXC(...)` via `ibm_db_dbi`).

2. **UTF-8 IFS Source Files Require `TGTCCSID(*JOB)` (`RNS9380`)**:
   - All source files in Git/IFS are UTF-8 (`CCSID 1208`).
   - When compiling `.sqlrpgle` files with `CRTSQLRPGI` from `SRCSTMF`, `COMPILEOPT` **must** include `TGTCCSID(*JOB)` (and `RPGPPOPT(*LVL2)`), otherwise the RPG compiler fails with `RNS9380: The source file CCSID 1208 is a Unicode CCSID which cannot be used with TGTCCSID(*SRC)`.

3. **Include Path Resolution Across `makei` and `RUCRTRPG` (`RNF0273` & `CPD0047`)**:
   - The VS Code **IBM i Testing** extension invokes `RPGUNIT/RUCRTRPG` with `INCDIR` set to the **deployment workspace root** (e.g., `INCDIR('/home/user/builds/ibm-i-packager')`).
   - Furthermore, `RUCRTRPG` forwards `INCDIR` to `CRTSQLRPGI`'s top-level `INCDIR` parameter, which **only accepts a single directory** (`CPD0047: List or expression not valid for parameter INCDIR` if multiple directories are passed in `testing.json`).
   - Therefore:
     - Do **not** add multiple `incDir` entries to [`.vscode/testing.json`](.vscode/testing.json) or [`test/qrpglesrc/testing.json`](test/qrpglesrc/testing.json).
     - In [`test/qrpglesrc/pkgtest.test.sqlrpgle`](test/qrpglesrc/pkgtest.test.sqlrpgle), always include shared headers using the workspace-root-relative path:
       ```rpgle
       /include 'src/qrpglesrc/PKGTYPES.rpgleinc'
       ```
     - Keep `"."` in `"includePath"` in [`iproj.json`](iproj.json) so both `makei` and `RUCRTRPG` resolve `'src/qrpglesrc/PKGTYPES.rpgleinc'`.

4. **ILE RPG `TEMPLATE` vs. `BASED` Keyword Rule (`RNF3323`)**:
   - In ILE RPG (`**FREE`), a data structure (`dcl-ds`) **cannot** specify both `template` and `based(...)` unless it is a subfield or used only via `likeds(...) based(...)` on the instance.
   - In [`src/qrpglesrc/PKGTYPES.rpgleinc`](src/qrpglesrc/PKGTYPES.rpgleinc), keep `dcl-ds ... qualified template;` without `based(...)`, and put `based(Ptr)` on the local `dcl-ds ... likeds(...) based(Ptr);` declaration.

5. **Variable-Length Buffer Parameters on QSYS APIs (`RNF7030`)**:
   - In [`src/qrpglesrc/PKGTYPES.rpgleinc`](src/qrpglesrc/PKGTYPES.rpgleinc), `QLICOBJD`'s 4th parameter (`ChgInfo`) is prototyped as `likeds(ChgObjUsrDfnAtr_t)`. Every caller must declare a local `dcl-ds ChgReq likeds(ChgObjUsrDfnAtr_t) inz(*likeds);` and pass `ChgReq`.

6. **Save File Object Listing API is `QSRLSAVF` (`SAVF0200`)**:
   - The IBM i system API to list objects inside a `*SAVF` into a user space (`*USRSPC`) is **`QSRLSAVF`** with format **`'SAVF0200'`** (7 parameters: `QualUsrSpc`, `'SAVF0200'`, `QualSavfName`, `'*ALL      '`, `'*ALL      '`, `ContHandle` `*blanks`, `ApiErr`). Never use `QSZRTVSO` (which does not exist on IBM i and causes `MCH3401`).

7. **Avoid LOB Locators Under `COMMIT(*NONE)` (`SQL0443`)**:
   - `PACKR` and `UNPACKR` run with `COMMIT = *NONE`.
   - Do **not** use `QSYS2.GET_CLOB_FROM_FILE(...)` in `COMMIT(*NONE)` programs—it returns a CLOB locator that fails at runtime with `SQLCODE -443` (`SQL0443`).
   - Instead, read IFS files using `TABLE(QSYS2.IFS_READ_UTF8(PATH_NAME => :Path))` into a `varchar(32000)` variable and pass that variable to `JSON_TABLE(:JsonDoc, ...)`.

