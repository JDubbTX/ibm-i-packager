# ============================================================================
# Makefile for IBM i CI/CD Packager (#PACK and #UNPACK), TOBi Samples & Tests
# Usage in PASE:
#   makei build -e lib1=CICDTOOLS
#   cd samples && makei build -e samplelib=PKGSAMPLE
#   -- or via gmake: --
#   gmake all BIN_LIB=CICDTOOLS
#   gmake tobi-samples SAMPLE_LIB=PKGSAMPLE
#   gmake test BIN_LIB=CICDTOOLS RPGUNIT_LIB=RPGUNIT
# ============================================================================
BIN_LIB     ?= CICDTOOLS
SAMPLE_LIB  ?= PKGSAMPLE
RPGUNIT_LIB ?= RPGUNIT
MAKEI       ?= /QOpenSys/pkgs/bin/makei
SRC_DIR     := $(CURDIR)/src
SAMPLES_DIR := $(CURDIR)/samples
TEST_DIR    := $(CURDIR)/test
INC_DIR     := $(SRC_DIR)/qrpglesrc

.PHONY: all clean lib build-pgm pack unpack tobi-build tobi-samples test-build test

all: lib build-pgm pack unpack

lib:
	-system -i "CRTLIB LIB($(BIN_LIB)) TEXT('IBM i CI/CD Packager Tools')"

build-pgm:
	system -i "CRTBNDCL PGM($(BIN_LIB)/BUILD) SRCSTMF('$(SRC_DIR)/qcllesrc/BUILD.clle') DFTACTGRP(*NO) ACTGRP(*NEW) REPLACE(*YES) DBGVIEW(*SOURCE)"

pack:
	system -i "CRTSQLRPGI OBJ($(BIN_LIB)/PACKR) SRCSTMF('$(SRC_DIR)/qrpglesrc/PACKR.sqlrpgle') COMMIT(*NONE) OBJTYPE(*PGM) RPGPPOPT(*LVL2) INCDIR('$(INC_DIR)') REPLACE(*YES) DBGVIEW(*SOURCE)"
	system -i "CRTBNDCL PGM($(BIN_LIB)/PACKC) SRCSTMF('$(SRC_DIR)/qcllesrc/PACKC.clle') DFTACTGRP(*NO) ACTGRP(*NEW) REPLACE(*YES) DBGVIEW(*SOURCE)"
	system -i "CRTCMD CMD($(BIN_LIB)/#PACK) PGM($(BIN_LIB)/PACKC) SRCSTMF('$(SRC_DIR)/qcmdsrc/PACK.cmd') ALLOW(*ALL) REPLACE(*YES)"

unpack:
	system -i "CRTSQLRPGI OBJ($(BIN_LIB)/UNPACKR) SRCSTMF('$(SRC_DIR)/qrpglesrc/UNPACKR.sqlrpgle') COMMIT(*NONE) OBJTYPE(*PGM) RPGPPOPT(*LVL2) INCDIR('$(INC_DIR)') REPLACE(*YES) DBGVIEW(*SOURCE)"
	system -i "CRTBNDCL PGM($(BIN_LIB)/UNPACKC) SRCSTMF('$(SRC_DIR)/qcllesrc/UNPACKC.clle') DFTACTGRP(*NO) ACTGRP(*NEW) REPLACE(*YES) DBGVIEW(*SOURCE)"
	system -i "CRTCMD CMD($(BIN_LIB)/#UNPACK) PGM($(BIN_LIB)/UNPACKC) SRCSTMF('$(SRC_DIR)/qcmdsrc/UNPACK.cmd') ALLOW(*ALL) REPLACE(*YES)"

tobi-build: lib
	$(MAKEI) build -e lib1=$(BIN_LIB)

tobi-samples:
	-system -i "CRTLIB LIB($(SAMPLE_LIB)) TEXT('Sample Objects Built by IBM i TOBi')"
	cd $(SAMPLES_DIR) && $(MAKEI) build -e samplelib=$(SAMPLE_LIB)

test-build: all
	system -i "ADDLIBLE $(RPGUNIT_LIB); ADDLIBLE $(BIN_LIB); $(RPGUNIT_LIB)/RUCRTRPG TSTPGM($(BIN_LIB)/TPKGTEST) SRCSTMF('$(TEST_DIR)/qrpglesrc/pkgtest.test.sqlrpgle') COPTION(*EVENTF *SRCSTMT *NODEBUGIO) DBGVIEW(*SOURCE) RPGPPOPT(*LVL2) INCDIR('$(INC_DIR)')"

test: test-build
	system -i "ADDLIBLE $(RPGUNIT_LIB); ADDLIBLE $(BIN_LIB); $(RPGUNIT_LIB)/RUCALLTST TSTPGM($(BIN_LIB)/TPKGTEST) TSTPRC(*ALL) DETAIL(*ALL)"

clean:
	-system -i "DLTCMD CMD($(BIN_LIB)/#PACK)"
	-system -i "DLTCMD CMD($(BIN_LIB)/#UNPACK)"
	-system -i "DLTPGM PGM($(BIN_LIB)/BUILD)"
	-system -i "DLTPGM PGM($(BIN_LIB)/PACKC)"
	-system -i "DLTPGM PGM($(BIN_LIB)/PACKR)"
	-system -i "DLTPGM PGM($(BIN_LIB)/UNPACKC)"
	-system -i "DLTPGM PGM($(BIN_LIB)/UNPACKR)"
	-system -i "DLTSRVPGM SRVPGM($(BIN_LIB)/TPKGTEST)"
