CONFIG=Makefile.config
SHELL := /bin/bash

include $(CONFIG)

default: build

build:

	cp etc/awesant/agent.conf.in etc/awesant/agent.conf;
	sed -i "s!@@FILE@@!$(LOGDIR)/awesant/agent.log!" etc/awesant/agent.conf;

	for file in \
		bin/awesant \
		etc/init.d/awesant-agent \
		etc/systemd/awesant-agent.service \
	; do \
		cp -a $$file.in $$file; \
		sed -i "s!@@PERL@@!$(PERL)!g" $$file; \
		sed -i "s!@@PREFIX@@!$(PREFIX)!g" $$file; \
		sed -i "s!@@CONFDIR@@!$(CONFDIR)!g" $$file; \
		sed -i "s!@@RUNDIR@@!$(RUNDIR)!g" $$file; \
		sed -i "s!@@LIBDIR@@!$(LIBDIR)!g" $$file; \
	done;

	if test "$(WITHOUT_PERL)" = "0" ; then \
		if test "$(PERL_DESTDIR)" ; then \
			set -e; cd perl; \
			$(PERL) Build.PL --installdirs $(PERL_INSTALLDIRS); \
		else \
			set -e; cd perl; \
			$(PERL) Build.PL --installdirs $(PERL_INSTALLDIRS) --destdir $(PERL_DESTDIR); \
		fi; \
		$(PERL) Build manifest; \
		$(PERL) Build; \
	fi;

test:

	if test "$(WITHOUT_PERL)" = "0" ; then \
		set -e; cd perl; \
		$(PERL) Build test; \
	fi;

install:

	# install the configuration
	if test ! -e "$(CONFDIR)/awesant" && test ! -L "$(CONFDIR)/awesant" ; then \
		./install-sh -d -m 0750 $(CONFDIR)/awesant; \
		./install-sh -c -m 0640 etc/awesant/agent.conf $(CONFDIR)/awesant/agent.conf; \
	fi;

	# create the logfile path
	if test ! -e "$(LOGDIR)/awesant" ; then \
		./install-sh -d -m 0750 $(LOGDIR)/awesant; \
	fi;

	# install the awesant agent
	if test ! -e "$(PREFIX)/bin" ; then \
		./install-sh -d -m 0755 $(PREFIX)/bin; \
	fi;

	./install-sh -c -m 0755 bin/awesant $(PREFIX)/bin/awesant
	./install-sh -c -m 0755 bin/awesant-create-cert $(PREFIX)/bin/awesant-create-cert

	if test $(BUILDPKG) -eq 0 ; then \
		if [ -e /bin/systemctl ] || [ -e /usr/bin/systemctl ] ; then \
			./install-sh -c -m 0755 etc/systemd/awesant-agent.service $(INITDIR)/awesant-agent.service; \
		fi; \
		./install-sh -c -m 0755 etc/init.d/awesant-agent $(INITDIR)/awesant-agent; \
	fi;

	# install the awesant agent perl modules
	if test "$(WITHOUT_PERL)" = "0" ; then \
		set -e; cd perl; $(PERL) Build install; $(PERL) Build realclean; \
	fi;

clean:

	if test "$(WITHOUT_PERL)" = "0" ; then \
		cd perl; \
		if test -e "Build" ; then \
			$(PERL) Build realclean; \
		fi; \
	fi;
