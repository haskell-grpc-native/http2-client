#!/bin/bash

query() {
  local verb=$1
  local host=$2
  local port=$3
  local path=$4

  http2-client-exe \
	--initial-window-kick 10000000 \
	--delay-before-quitting-ms 2000 \
	--verb $verb \
	--host $host \
	--port $port \
	--path $path
}

commit=`git rev-parse HEAD | head -c 8`

mkdir -p $commit

for host in `grep -v '^#' $1`; do
	path="${commit}/${host}"
	echo "**************************************"
	echo $host
        query GET $host 443 / > $path
done
