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
	for f in \
	    `find -name \*.sh` \
	    hostscripts/ci1/* \
	    hostscripts/clouddata/{syncSLErepos,syncgitrepos} \
	    hostscripts/gatehost/{sudo-freshadminvm,freshadminvm} \
	    hostscripts/nagios/ci-o-o \
	    mkcloudruns/*/[^R]*\
	    scripts/{mkcloud,mkchroot,repochecker} \
	    scripts/jenkins/update_automation \
	    scripts/mkcloudhost/{runtestn,mkcloud_free_pool,mkcloude,fixlibvirt,generate-radvd-conf} \
	    scripts/mkcloudhost/{runtestmulticloud,boot.local,boot.mkcloud,mkcloud_reserve_pool,runtestn} \
	    scripts/mkcloudhost/{routed.cloud,hacloud.common,cloudrc.host,cloudfunc} \
	    ; \
	do \
	    echo "checking $$f"; \
	    bash -n $$f || exit 3; \
	    bashate --ignore E006,E010,E011,E020,E042 $$f || exit 4; \
	    ! grep $$'\t' $$f || exit 5; \
	done

perlcheck:
	cd scripts && \
	for f in `find -name \*.pl` jenkins/{apicheck,grep,japi} mkcloudhost/{allocpool,correlatevirsh} ; \
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
	    python2 -m py_compile $$f || exit 22; \
	    python3 -m py_compile $$f || exit 22; \
	done

rounduptest:
	cd scripts && roundup
	cd scripts/jenkins && roundup

flake8:
	flake8 .

python_unittest:
	python2 -m unittest discover -v
	python3 -m unittest discover -v

gerrit-project-regexp:
	scripts/jenkins/cloud/gerrit/project-map2project-regexp.py master > jenkins/ci.suse.de/gerrit-project-regexp-cloud9.txt
	scripts/jenkins/cloud/gerrit/project-map2project-regexp.py stable/pike > jenkins/ci.suse.de/gerrit-project-regexp-cloud8.txt

jjb_test: gerrit-project-regexp
	jenkins-jobs --ignore-cache test jenkins/ci.suse.de:jenkins/ci.suse.de/templates/ cloud* openstack* > /dev/null
	jenkins-jobs --ignore-cache test jenkins/ci.opensuse.org:jenkins/ci.opensuse.org/templates/ cloud* openstack* > /dev/null

cisd_deploy: gerrit-project-regexp
	jenkins-jobs --conf /etc/jenkins_jobs/jenkins_jobs-cisd.ini update jenkins/ci.suse.de:jenkins/ci.suse.de/templates/ cloud\* openstack\* ardana\*

cioo_deploy:
	jenkins-jobs --conf /etc/jenkins_jobs/jenkins_jobs-cioo.ini update jenkins/ci.opensuse.org:jenkins/ci.opensuse.org/templates/ openstack*

shellcheck:
	shellcheck `grep -Erl '^#! ?/bin/b?a?sh'`

install:
	sudo zypper install perl-JSON-XS perl-libxml-perl perl-libwww-perl python-pip python3-pip libvirt-python python3-libvirt-python
	sudo pip2 install -U bashate flake8 flake8-import-order jenkins-job-builder
	sudo pip3 install -U bashate flake8 flake8-import-order jenkins-job-builder
	git clone https://github.com/SUSE-Cloud/roundup && \
	cd roundup && \
	./configure && \
	make && \
	sudo make install
