# Copyright (c) 2010 Electric Cloud, Inc.
# All rights reserved

SRCTOP = ..
include $(SRCTOP)/build/vars.mak

build: package
unittest:
systemtest: start-selenium test-setup test-run stop-selenium
scmtest:
	$(MAKE) NTESTFILES="systemtest/svn.ntest" RUNSCMTESTS=1 test-setup test-run

NTESTFILES ?= systemtest

test-setup:
	$(EC_PERL) ../ECSCM/systemtest/setup.pl $(TEST_SERVER) $(PLUGINS_ARTIFACTS)

test-run: systemtest-run

test: uninstall build install promote
uninstall:
	ectool uninstallPlugin ECSCM-Mercurial-1.0.2.0
install:
	ectool installPlugin ../../../out/common/nimbus/ECSCM-Mercurial/ECSCM-Mercurial.jar
promote:
	ectool promotePlugin ECSCM-Mercurial-1.0.2.0

include $(SRCTOP)/build/rules.mak
