# Test Suite Rules (`test/`)

These rules apply when modifying or running the **iRPGUnit (`RPGUNIT`)** test suite under [`test/`](.).

---

## 1. VS Code IBM i Testing Extension Discovery & Naming

- **Test File**: [`test/qrpglesrc/pkgtest.test.sqlrpgle`](qrpglesrc/pkgtest.test.sqlrpgle)
  - Must retain the `.test.sqlrpgle` suffix so the **IBM i Testing** VS Code extension automatically discovers it in the Test Explorer.
  - Compiles to service program **`TPKGTEST.SRVPGM`** (derived from `T` + `PKGTEST`) in the current library (`PACKAGER`).
- **Configuration Files**:
  - [`.vscode/testing.json`](../.vscode/testing.json) and [`test/qrpglesrc/testing.json`](qrpglesrc/testing.json) configure `rucrtrpg` and `rucalltst`.
  - **CRITICAL**: Do **not** add a multi-entry `"incDir"` array to `testing.json`. The IBM i Testing extension automatically passes the remote deployment root directory (`INCDIR('/home/<user>/builds/ibm-i-packager')`) to `RUCRTRPG`. Adding extra `incDir` entries causes `CRTSQLRPGI` inside `RUCRTRPG` to fail with `CPD0047: List or expression not valid for parameter INCDIR`.
- **Include Directives in `pkgtest.test.sqlrpgle`**:
  - Always use the workspace-root-relative path for project copybooks:
    ```rpgle
    /include qinclude,TESTCASE
    /include 'src/qrpglesrc/PKGTYPES.rpgleinc'
    ```

---

## 2. Test Lifecycle & Fixture Invariants

1. **`setUpSuite` Command Setup (`PACK` / `#PACK` and `UNPACK` / `#UNPACK`)**:
   - When built via TOBi (`makei`), the commands in the build library (`PACKAGER`) are named `PACK` and `UNPACK`.
   - `setUpSuite` queries `QSYS2.OBJECT_STATISTICS('*LIBL', '*PGM', 'PACKC')` to locate `ToolLib` (default `'PACKAGER'`), ensures `PACK` and `UNPACK` point to `ToolLib/PACKC` and `ToolLib/UNPACKC`, and duplicates them as `#PACK` and `#UNPACK` in `ToolLib`.
   - **Never** pass `FROMLIB(*LIBL)` to `CRTDUPOBJ`—IBM i rejects `*LIBL` on `CRTDUPOBJ FROMLIB` with `CPD0078`. Always pass the resolved library name (`ToolLib`).
2. **Test Fixture Libraries**:
   - `setUpSuite` creates and populates four scratch libraries:
     - `PKGTSTSRC`: Source fixture library containing 12 objects across all tiers (`TSTDTAARA`, `TSTDTAQ`, `TSTMSGF`, `TSTCUSTPF`, `TSTSYSCFG`, `TSTCUSTVW`, `TSTMOD1`, `TSTBNDDIR`, `TSTSRVPGM`, `TSTPGM1`, `TSTCLPGM`, `TSTCMD1`).
     - `PKGTSTTGT`: Empty target library for single-library precedence unpack tests.
     - `PKGTSTDTA`: Target data library for multi-library JSON `MAPFILE` routing tests.
     - `PKGTSTPGM`: Target program library for multi-library JSON `MAPFILE` routing tests.
   - `setUp` clears `PKGTSTTGT`, `PKGTSTDTA`, `PKGTSTPGM`, resets `USRDFNATR` stamps on all 12 objects in `PKGTSTSRC` via `ResetObjVersionStamp`, and removes temporary `/tmp/pkgtest_*` IFS files so every `test*` procedure can run in any order (`ORDER(*API)` or individually).
   - `tearDownSuite` deletes all four `PKGTST*` libraries and cleans up `/tmp/pkgtest_*` artifacts.

---

## 3. Compiling & Running Tests From PASE / CLI

Because `RUCRTRPG` (`CRTSQLRPGI`) and `RUCALLTST` cannot run in a multithreaded job (`system -i` fails with `CPD000D`), run them from PASE via Python `ibm_db_dbi` (`QCMDEXC` in a single-threaded `QSQSRVR` job):

```bash
/QOpenSys/pkgs/bin/python3.6 -c "
import ibm_db_dbi
conn = ibm_db_dbi.connect()
cur = conn.cursor()
for cmd in [
    'CHGCURLIB CURLIB(PACKAGER)',
    'ADDLIBLE LIB(RPGUNIT)',
    'ADDLIBLE LIB(PACKAGER)',
    \"RPGUNIT/RUCRTRPG TSTPGM(PACKAGER/TPKGTEST) SRCSTMF('/home/jweirich/builds/ibm-i-packager/test/qrpglesrc/pkgtest.test.sqlrpgle') TGTCCSID(*JOB) DBGVIEW(*SOURCE) COPTION(*EVENTF *SRCSTMT *NODEBUGIO) RPGPPOPT(*LVL2) INCDIR('/home/jweirich/builds/ibm-i-packager')\",
    \"RPGUNIT/RUCALLTST TSTPGM(PACKAGER/TPKGTEST) TSTPRC(*ALL) ORDER(*API) DETAIL(*ALL) OUTPUT(*ALLWAYS) LIBL(*CURRENT) JOBD(*DFT) RCLRSC(*NO) XMLSTMF('/tmp/tpkgtest_all.xml')\"
]:
    cur.execute('CALL QSYS2.QCMDEXC(?)', (cmd,))
"
cat /tmp/tpkgtest_all.xml
```

