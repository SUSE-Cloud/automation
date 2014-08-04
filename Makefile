SHELL := /bin/bash
test:
	cd scripts ; for f in *.sh mkcloud mkchroot jenkins/{update_automation,*.sh} ; do echo "checking $$f" ; bash -n $$f || exit 3 ; bash8 --ignore E010,E020 $$f || exit 4 ; done
	cd scripts ; for f in *.pl jenkins/{apicheck,jenkins-job-trigger,*.pl} ; do perl -c $$f || exit 2 ; done

# for travis-CI:
install:
	sudo apt-get update
	sudo apt-get -y install libxml-libxml-perl libjson-xs-perl
	sudo pip install bash8
