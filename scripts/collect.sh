#!/bin/bash

query() {
  local verb=$1
  local host=$2
  local port=$3
  local path=$4
  local ppprefix=$5

  http2-client-exe \
	--initial-window-kick 10000000 \
	--delay-before-quitting-ms 2000 \
	--verb $verb \
	--host $host \
	--port $port \
	--path $path \
	--push-files-prefix $ppprefix
}

commit=`git rev-parse HEAD | head -c 8`

mkdir -p $commit

for host in `grep -v '^#' $1`; do
	dir="${commit}/${host}"
	echo "**************************************"
	echo $host
	mkdir $dir
        query GET $host 443 / $dir
done
