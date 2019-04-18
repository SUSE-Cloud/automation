SHELL := /bin/bash
test: filecheck bashate perlcheck rubycheck pythoncheck rounduptest flake8 python_unittest jjb_test

clean:
	rm -f scripts/jenkins/jenkins-job-triggerc scripts/lib/libvirt/{net-configc,vm-startc,compute-configc,net-startc,admin-configc,cleanupc}
	find -name \*.pyc -print0 | xargs -0 rm -f

filecheck:
	! git ls-tree -r HEAD --name-only | \
		egrep -v 'Makefile|sample-logs/.*\.txt$$' | \
		xargs grep $$'\t'

bashate:
	cd scripts && \
	for f in \
	    *.sh mkcloud mkchroot repochecker \
	    jenkins/{update_automation,*.sh} \
	    ../hostscripts/ci1/* ../hostscripts/clouddata/syncSLErepos ../mkcloudruns/*/[^R]*;\
	do \
	    echo "checking $$f"; \
	    bash -n $$f || exit 3; \
	    bashate --ignore E006,E010,E011,E020,E042 $$f || exit 4; \
	    ! grep $$'\t' $$f || exit 5; \
	done

perlcheck:
	cd scripts && \
	for f in `find -name \*.pl` jenkins/{apicheck,grep,japi} mkcloudhost/allocpool ; \
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
	cd scripts/jenkins && roundup

flake8:
	flake8 scripts/ hostscripts/soc-ci/soc-ci

python_unittest:
	python -m unittest discover -v -s scripts/lib/libvirt/

gerrit-project-regexp:
	scripts/jenkins/ardana/gerrit/project-map2project-regexp.py master > jenkins/ci.suse.de/gerrit-project-regexp-cloud9.txt
	scripts/jenkins/ardana/gerrit/project-map2project-regexp.py stable/pike > jenkins/ci.suse.de/gerrit-project-regexp-cloud8.txt

jjb_test: gerrit-project-regexp
	jenkins-jobs --ignore-cache test jenkins/ci.suse.de:jenkins/ci.suse.de/templates/ cloud* openstack* > /dev/null
	jenkins-jobs --ignore-cache test jenkins/ci.opensuse.org:jenkins/ci.opensuse.org/templates/ cloud* openstack* > /dev/null

cisd_deploy: gerrit-project-regexp
	jenkins-jobs --conf /etc/jenkins_jobs/jenkins_jobs-cisd.ini update jenkins/ci.suse.de:jenkins/ci.suse.de/templates/ cloud\* openstack\* ardana\*

cioo_deploy:
	jenkins-jobs --conf /etc/jenkins_jobs/jenkins_jobs-cioo.ini update jenkins/ci.opensuse.org:jenkins/ci.opensuse.org/templates/ openstack*

# for travis-CI:
install: debianinstall genericinstall

debianinstall:
	sudo apt-get update -qq
	sudo apt-get -y install libxml-libxml-perl libjson-perl libjson-xs-perl python-libvirt

suseinstall:
	sudo zypper install perl-JSON-XS perl-libxml-perl python-pip libvirt-python

genericinstall:
	sudo pip install -U 'pbr>=2.0.0,!=2.1.0' bashate 'flake8<3.0.0' flake8-import-order jenkins-job-builder requests
	git clone https://github.com/SUSE-Cloud/roundup && \
	cd roundup && \
	./configure && \
	make && \
	sudo make install

shellcheck:
	shellcheck `grep -Erl '^#! ?/bin/b?a?sh'`
