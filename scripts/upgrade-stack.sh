set -xe
lts=$1
echo "upgrading to Stack-LTS ${lts}"
cp "stack.yaml" "stack-lts-${lts}.yaml"
rm "stack.yaml"
sed -i '' "s/^resolver: .*$/resolver: lts-${lts}/" "stack-lts-${lts}.yaml"
ln -s "stack-lts-${lts}.yaml" "stack.yaml" 
