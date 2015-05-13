SHELL := /bin/bash
test: bashate perlcheck rounduptest flake8

bashate:
	cd scripts && \
	for f in \
	    *.sh mkcloud mkchroot repochecker \
	    jenkins/{update_automation,*.sh} \
	    jenkins/ci1/*; \
	do \
	    echo "checking $$f"; \
	    bash -n $$f || exit 3; \
	    bashate --ignore E010,E011,E020 $$f || exit 4; \
	    ! grep $$'\t' $$f || exit 5; \
	done

perlcheck:
	cd scripts && \
	for f in *.pl jenkins/{apicheck,jenkins-job-trigger,*.pl}; \
	do \
	    perl -c $$f || exit 2; \
	done

rounduptest:
	cd scripts && roundup

flake8:
	flake8 scripts/

# for travis-CI:
install: debianinstall genericinstall

debianinstall:
	sudo apt-get update -qq
	sudo apt-get -y install libxml-libxml-perl libjson-xs-perl

suseinstall:
	sudo zypper install perl-JSON-XS perl-libxml-perl

genericinstall:
	sudo pip install bashate flake8
	git clone https://github.com/SUSE-Cloud/roundup && \
	cd roundup && \
	./configure && \
	make && \
	sudo make install

