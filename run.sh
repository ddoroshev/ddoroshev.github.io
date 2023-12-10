#!/usr/bin/env bash

set -exuo pipefail

docker run -p 80:80 -v $(pwd):/site --name blog --rm blog serve -H 0 -P 80 --force-polling -l
