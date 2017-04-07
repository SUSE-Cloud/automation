#!/bin/sh
echo "@fip@" > index.html
chmod 644 index.html

for i in $(seq @num_web_servers@); do
    thttpd -p $(( 79 + $i ))
done

