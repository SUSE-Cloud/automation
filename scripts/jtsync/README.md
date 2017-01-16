# jtsync - synchronize status from jenkins to trello
    Usage: jtsync --ci SERVICE (--matrix|--job) JOB_STATUS
            --ci SERVICE                 Which ci is used (suse or opensuse)
            --matrix NAME,PROJECT        Set status of a matrix job
            --job NAME                   Set status of a normal job

Matrix job cards are selected in this form:

    $ jtsync --ci suse --matrix cloud-trackupstream,Devel:Cloud:7:Staging

The script never returns anything other than `0` to make sure jenkins runs are not interruped
by the script.


## Run the script on a developer machine
Install `bundler` before continue:

    cd <path to jtsync directory>
    bundler install --path=~/.bundle-jtsync
    bundle exec jtsync.rb
    ...

## How to test:
In general there is the `test_jtsync` script to run an manual test run. You need
to create credentials for the trello API (you can create credentials [here](https://trello.com/app-key))
Place them in your local `.netrc` file:

    machine api.trello.com
      login <developer token>
      password <member token>


A test board is available here: [https://trello.com/b/fL7fv67z/jtsync](https://trello.com/b/fL7fv67z/jtsync)
It can be just used or cloned when a own board is desired.

Replace the _hardcoded_ __board id__ in `jtsync.rb` to your test __board id__.
Make sure that the following structure exists:

    Board
    |---- Cloud 7
    |     |---- cloud-mkcloud7-job-4nodes-linuxbridge-x86-64
    |     '---- C7 crowbar-trackupstream
    '---- OpenStack
          '---- cleanvm: Juno

The two labels `successful` and `failed` __must__ exist!

__Run the script:__

    $ bundle exec ./test_jtsync.sh
    set (Cloud 7) cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 to failed
    returncode: 0
    Press any key to continue... 
    set (Cloud 7) cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 to failed (no notification)
    returncode: 0
    Press any key to continue... 
    set (Cloud 7) cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 to success
    returncode: 0
    Press any key to continue...
    ...
