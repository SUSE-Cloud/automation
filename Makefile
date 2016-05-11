SHELL := /bin/bash
test: bashate perlcheck rubycheck pythoncheck rounduptest flake8 python_unittest jjb_test

bashate:
	cd scripts && \
	for f in \
	    *.sh mkcloud mkchroot repochecker \
	    jenkins/{update_automation,*.sh} \
	    jenkins/ci1/*; \
	do \
	    echo "checking $$f"; \
	    bash -n $$f || exit 3; \
	    bashate --ignore E006,E010,E011,E020,E042 $$f || exit 4; \
	    ! grep $$'\t' $$f || exit 5; \
	done

perlcheck:
	cd scripts && \
	for f in `find -name \*.pl` jenkins/{apicheck,grep,japi}; \
	do \
	    perl -wc $$f || exit 2; \
	done

rubycheck:
	for f in `find -name \*.rb` scripts/jenkins/jenkinslog; \
	do \
	    ruby -wc $$f || exit 2; \
	done

pythoncheck:
	for f in `find -name \*.py` scripts/lib/libvirt/{admin-config,cleanup,compute-config,net-config,net-start,vm-start} scripts/jenkins/jenkins-job-trigger; \
        do \
	    python -m py_compile $$f || exit 22; \
	done

rounduptest:
	cd scripts && roundup

flake8:
	flake8 scripts/

python_unittest:
	python -m unittest discover -v -s scripts/lib/libvirt/

jjb_test:
	sudo pip install jenkins-job-builder
	jenkins-jobs --ignore-cache test scripts/jenkins/jobs-ibs:scripts/jenkins/jobs-ibs/templates/ cloud* openstack*
	jenkins-jobs --ignore-cache test scripts/jenkins/jobs-obs cloud* openstack*

# for travis-CI:
install: debianinstall genericinstall

debianinstall:
	sudo apt-get update -qq
	sudo apt-get -y install libxml-libxml-perl libjson-xs-perl python-libvirt

suseinstall:
	sudo zypper install perl-JSON-XS perl-libxml-perl python-pip libvirt-python

genericinstall:
	sudo pip install bashate flake8 flake8-import-order
	git clone https://github.com/SUSE-Cloud/roundup && \
	cd roundup && \
	./configure && \
	make && \
	sudo make install

