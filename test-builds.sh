#!/bin/bash
set -e
stack build --stack-yaml=stack-lts-12.14.yaml
stack build --stack-yaml=stack-lts-14.27.yaml
stack build --stack-yaml=stack-lts-17.2.yaml
stack build --stack-yaml=stack-lts-18.3.yaml
