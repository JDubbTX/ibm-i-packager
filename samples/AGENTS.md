# Sample Object Suite Rules (`samples/`)

These rules apply when modifying the multi-tier sample IBM i objects and TOBi (`makei`) build rules under [`samples/`](.).

---

## 1. Recognized TOBi (`makei`) Source File Extensions

IBM i TOBi (`makei`) decomposes source filenames by extension (`makei/utils.py:decompose_filename`). Using an unrecognized extension causes `makei` to crash with `ValueError: Cannot decompose filename` before running any build target.

Always use these exact extensions in `samples/`:

| IBM i Object Type | Required Source Extension | Target Extension in `Rules.mk` |
| :--- | :--- | :--- |
| `*DTAARA` | `.DTAARA` (CL creation script) | `.DTAARA` |
| `*MSGF` | `.MSGF` (CL creation script) | `.MSGF` |
| `*BNDDIR` | `.BNDDIR` (CL creation script) | `.BNDDIR` |
| `*FILE` (DDS Physical File) | `.PF` | `.FILE` |
| `*FILE` (DDS Logical File) | `.LF` | `.FILE` |
| `*FILE` (DDS Display File) | `.DSPF` | `.FILE` |
| `*FILE` (DDS Printer File) | `.PRTF` | `.FILE` |
| `*FILE` (SQL Table) | `.TABLE` | `.FILE` |
| `*FILE` (SQL View) | `.VIEW` | `.FILE` |
| `*PNLGRP` (UIM Panel Group) | `.PNLGRP` | `.PNLGRP` |
| `*MODULE` (ILE RPG) | `.RPGLE` | `.MODULE` |
| `*SRVPGM` (Binder Source) | `.BND` | `.SRVPGM` |
| `*PGM` (SQLRPGLE) | `.SQLRPGLE` | `.PGM` |
| `*PGM` (ILE COBOL) | `.CBLLE` | `.PGM` |
| `*PGM` (ILE C) | `.C` | `.PGM` |
| `*PGM` (ILE CL) | `.CLLE` | `.PGM` |
| `*CMD` (CL Command) | `.CMD` | `.CMD` |

---

## 2. Crucial TOBi `crtfrmstmf` Rules in `Rules.mk`

1. **Suppress `*EVENTF` on Commands That Do Not Generate Event Files (`CPFA0A9`)**:
   - TOBi's `crtfrmstmf` script passes `OPTION(*EVENTF *SRC *LIST)` by default and then attempts to copy `/QSYS.LIB/<lib>.LIB/EVFEVENT.FILE/<obj>.MBR`.
   - On IBM i, `CRTPF`, `CRTLF`, `CRTDSPF`, `CRTPRTF`, `CRTPNLGRP`, and `CRTCMD` do **not** always produce an `EVFEVENT` member unless supported/enabled, causing `crtfrmstmf` to fail with `CPFA0A9: Object not found ... EVFEVENT.FILE/<obj>.MBR` (exit code 255) even though the object was created!
   - Therefore, always set `private OPTION = *SRC *LIST` (omitting `*EVENTF`) on DDS `.FILE`, `.PNLGRP`, and `.CMD` targets in:
     - [`samples/qddssrc/Rules.mk`](qddssrc/Rules.mk) (`CUSTPF.FILE`, `CUSTLF.FILE`, `CUSTDSPF.FILE`, `ORDPRTF.FILE`)
     - [`samples/qpnlsrc/Rules.mk`](qpnlsrc/Rules.mk) (`ORDHLP.PNLGRP`)
     - [`samples/qcmdsrc/Rules.mk`](qcmdsrc/Rules.mk) (`ORDENT.CMD`)

2. **CL Command (`CRTCMD`) Targets Require `PGM = ...`**:
   - In [`samples/qcmdsrc/Rules.mk`](qcmdsrc/Rules.mk), set both `CMD_PGM = ORDCL` and `PGM = ORDCL` on `ORDENT.CMD` so `CRTCMD` receives the required `PGM` parameter.

3. **Include Directory for Sample Copybooks**:
   - [`samples/qrpglesrc/TAXPROTO.RPGLEINC`](qrpglesrc/TAXPROTO.RPGLEINC) lives in `samples/qrpglesrc/`.
   - In [`samples/qrpglesrc/Rules.mk`](qrpglesrc/Rules.mk), keep `private INCDIR = 'samples/qrpglesrc'` (quoted) on `TAXMOD.MODULE` and `private INCDIR = samples/qrpglesrc` (unquoted) on `ORDPGM.PGM`.
   - TOBi passes `INCDIR($(INCDIR))` directly to `CRTRPGMOD`, where an unquoted path containing `/` fails with `CPD0049: Qualified name not valid for parameter INCDIR` (then `CPFA0A9` on the missing `EVFEVENT` member). `CRTSQLRPGI` targets receive `INCDIR` through TOBi's quoted `COMPILEOPT`, so `ORDPGM.PGM` stays unquoted.

